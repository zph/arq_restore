//
//  ArqRestoreCommand.m
//  arq_restore
//
//  Created by Stefan Reitshamer on 7/25/14.
//
//

#import "ArqRestoreCommand.h"
#import "Target.h"
#import "AWSRegion.h"
#import "BackupSet.h"
#import "S3Service.h"
#import "UserAndComputer.h"
#import "Bucket.h"
#import "Repo.h"


@implementation ArqRestoreCommand
- (void)dealloc {
    [target release];
    [super dealloc];
}

- (NSString *)errorDomain {
    return @"ArqRestoreCommandErrorDomain";
}

- (BOOL)executeWithArgc:(int)argc argv:(const char **)argv error:(NSError **)error {
    NSMutableArray *args = [NSMutableArray array];
    for (int i = 0; i < argc; i++) {
        [args addObject:[[[NSString alloc] initWithBytes:argv[i] length:strlen(argv[i]) encoding:NSUTF8StringEncoding] autorelease]];
    }
    
    if ([args count] < 2) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"missing arguments");
        return NO;
    }
    
    int index = 1;
    if ([[args objectAtIndex:1] isEqualToString:@"-l"]) {
        if ([args count] < 4) {
            SETNSERROR([self errorDomain], ERROR_USAGE, @"missing arguments");
            return NO;
        }
        setHSLogLevel(hsLogLevelForName([args objectAtIndex:2]));
        index += 2;
    }
    
    NSString *cmd = [args objectAtIndex:index];
    
    int targetParamsIndex = index + 1;
    if ([cmd isEqualToString:@"listcomputers"]) {
        // Valid command, but no additional args.
        
    } else if ([cmd isEqualToString:@"listfolders"]) {
        if ([args count] < 4) {
            SETNSERROR([self errorDomain], ERROR_USAGE, @"missing arguments for listfolders command");
            return NO;
        }
        targetParamsIndex = 4;
    } else if ([cmd isEqualToString:@"restore"]) {
        if ([args count] < 5) {
            SETNSERROR([self errorDomain], ERROR_USAGE, @"missing arguments");
            return NO;
        }
        targetParamsIndex = 5;
    } else {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"unknown command: %@", cmd);
        return NO;
    }
    
    if (targetParamsIndex >= argc) {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"missing target type params");
        return NO;
    }
    target = [[self targetForParams:[args subarrayWithRange:NSMakeRange(targetParamsIndex, argc - targetParamsIndex)] error:error] retain];
    if (target == nil) {
        return NO;
    }
    
    if ([cmd isEqualToString:@"listcomputers"]) {
        if (![self listComputers:error]) {
            return NO;
        }
    } else if ([cmd isEqualToString:@"listfolders"]) {
        if (![self listBucketsForComputerUUID:[args objectAtIndex:2] encryptionPassword:[args objectAtIndex:3] error:error]) {
            return NO;
        }
    } else if ([cmd isEqualToString:@"restore"]) {
        if (![self restoreComputerUUID:[args objectAtIndex:2] bucketUUID:[args objectAtIndex:4] encryptionPassword:[args objectAtIndex:3] error:error]) {
            return NO;
        }
    } else {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"unknown command: %@", cmd);
        return NO;
    }
    
    return YES;
}


#pragma mark internal
- (Target *)targetForParams:(NSArray *)theParams error:(NSError **)error {
    NSString *theTargetType = [theParams objectAtIndex:0];
    
    Target *ret = nil;
    if ([theTargetType isEqualToString:@"aws"]) {
        if ([theParams count] != 4) {
            SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid aws parameters");
            return nil;
        }
        
        NSString *theAccessKey = [theParams objectAtIndex:1];
        NSString *theSecretKey = [theParams objectAtIndex:2];
        NSString *theBucketName = [theParams objectAtIndex:3];
        AWSRegion *awsRegion = [self awsRegionForAccessKey:theAccessKey secretKey:theSecretKey bucketName:theBucketName error:error];
        if (awsRegion == nil) {
            return nil;
        }
        NSURL *s3Endpoint = [awsRegion s3EndpointWithSSL:YES];
        int port = [[s3Endpoint port] intValue];
        NSString *portString = @"";
        if (port != 0) {
            portString = [NSString stringWithFormat:@":%d", port];
        }
        NSURL *targetEndpoint = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@@%@%@/%@", [s3Endpoint scheme], theAccessKey, [s3Endpoint host], portString, theBucketName]];
        ret = [[[Target alloc] initWithEndpoint:targetEndpoint secret:theSecretKey passphrase:nil] autorelease];
    } else if ([theTargetType isEqualToString:@"sftp"]) {
        if ([theParams count] != 6 && [theParams count] != 7) {
            SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid sftp parameters");
            return nil;
        }
        
        NSString *hostname = [theParams objectAtIndex:1];
        int port = [[theParams objectAtIndex:2] intValue];
        NSString *path = [theParams objectAtIndex:3];
        NSString *username = [theParams objectAtIndex:4];
        NSString *secret = [theParams objectAtIndex:5];
        NSString *keyfilePassphrase = [theParams count] > 6 ? [theParams objectAtIndex:6] : nil;
        
        if (![path hasPrefix:@"/"]) {
            path = [@"/~/" stringByAppendingString:path];
        }
        NSString *escapedPath = (NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)path, NULL, (CFStringRef)@"!*'();:@&=+$,?%#[]", kCFStringEncodingUTF8);
        NSString *escapedUsername = (NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)username, NULL, (CFStringRef)@"!*'();:@&=+$,?%#[]", kCFStringEncodingUTF8);
        NSURL *endpoint = [NSURL URLWithString:[NSString stringWithFormat:@"sftp://%@@%@:%d%@", escapedUsername, hostname, port, escapedPath]];

        ret = [[[Target alloc] initWithEndpoint:endpoint secret:secret passphrase:keyfilePassphrase] autorelease];
    } else if ([theTargetType isEqualToString:@"greenqloud"]
               || [theTargetType isEqualToString:@"dreamobjects"]
               || [theTargetType isEqualToString:@"googlecloudstorage"]
               
               || [theTargetType isEqualToString:@"s3compatible"]) {
        if ([theParams count] != 4) {
            SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid %@ parameters", theTargetType);
            return nil;
        }
        
        NSString *theAccessKey = [theParams objectAtIndex:1];
        NSString *theSecretKey = [theParams objectAtIndex:2];
        NSString *theBucketName = [theParams objectAtIndex:3];
        NSString *theHostname = nil;
        if ([theTargetType isEqualToString:@"greenqloud"]) {
            theHostname = @"s.greenqloud.com";
        } else if ([theTargetType isEqualToString:@"dreamobjects"]) {
            theHostname = @"objects.dreamhost.com";
        } else if ([theTargetType isEqualToString:@"googlecloudstorage"]) {
            theHostname = @"storage.googleapis.com";
        } else {
            SETNSERROR([self errorDomain], ERROR_USAGE, @"no hostname for target type: %@", theTargetType);
            return nil;
        }
        
        NSURL *endpoint = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@@%@/%@", theAccessKey, theHostname, theBucketName]];
        ret = [[[Target alloc] initWithEndpoint:endpoint secret:theSecretKey passphrase:nil] autorelease];
    } else if ([theTargetType isEqualToString:@"googledrive"]) {
        if ([theParams count] != 3) {
            SETNSERROR([self errorDomain], ERROR_USAGE, @"invalid googledrive parameters");
            return nil;
        }
        
        NSString *theRefreshToken = [theParams objectAtIndex:1];
        NSString *thePath = [theParams objectAtIndex:2];
        
        NSString *escapedPath = (NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (CFStringRef)thePath, CFSTR("/"), CFSTR("@?=&+"), kCFStringEncodingUTF8);
        [escapedPath autorelease];
        
        NSURL *endpoint = [NSURL URLWithString:[NSString stringWithFormat:@"googledrive://unknown_email_address@www.googleapis.com%@", escapedPath]];
        ret = [[[Target alloc] initWithEndpoint:endpoint secret:theRefreshToken passphrase:nil] autorelease];
    } else {
        SETNSERROR([self errorDomain], ERROR_USAGE, @"unknown target type: %@", theTargetType);
        return nil;
    }
    return ret;
}

- (AWSRegion *)awsRegionForAccessKey:(NSString *)theAccessKey secretKey:(NSString *)theSecretKey bucketName:(NSString *)theBucketName error:(NSError **)error {
    return nil;
}

- (BOOL)listComputers:(NSError **)error {
    NSArray *expandedTargetList = [self expandedTargetList:error];
    if (expandedTargetList == nil) {
        return NO;
    }
    
    NSMutableArray *ret = [NSMutableArray array];
    for (Target *theTarget in expandedTargetList) {
        NSError *myError = nil;
        HSLogDebug(@"getting backup sets for %@", theTarget);
        
        NSArray *backupSets = [BackupSet allBackupSetsForTarget:theTarget targetConnectionDelegate:nil error:&myError];
        if (backupSets == nil) {
            if ([myError isErrorWithDomain:[S3Service errorDomain] code:S3SERVICE_ERROR_AMAZON_ERROR] && [[[myError userInfo] objectForKey:@"HTTPStatusCode"] intValue] == 403) {
                HSLogError(@"access denied getting backup sets for %@", theTarget);
            } else {
                HSLogError(@"error getting backup sets for %@: %@", theTarget, myError);
                SETERRORFROMMYERROR;
                return nil;
            }
        } else {
            printf("target: %s\n", [[theTarget endpointDisplayName] UTF8String]);
            for (BackupSet *backupSet in backupSets) {
                printf("\tcomputer %s\n", [[backupSet computerUUID] UTF8String]);
                printf("\t\t%s (%s)\n", [[[backupSet userAndComputer] computerName] UTF8String], [[[backupSet userAndComputer] userName] UTF8String]);
            }
        }
    }
    return ret;
}
- (NSArray *)expandedTargetList:(NSError **)error {
    NSMutableArray *expandedTargetList = [NSMutableArray arrayWithObject:target];
    if ([target targetType] == kTargetAWS
        || [target targetType] == kTargetDreamObjects
        || [target targetType] == kTargetGoogleCloudStorage
        || [target targetType] == kTargetGreenQloud
        || [target targetType] == kTargetS3Compatible) {
        NSError *myError = nil;
        NSArray *targets = [self expandedTargetsForS3Target:target error:&myError];
        if (targets == nil) {
            HSLogError(@"failed to expand target list for %@: %@", target, myError);
        } else {
            [expandedTargetList setArray:targets];
            HSLogDebug(@"expandedTargetList is now: %@", expandedTargetList);
        }
    }
    return expandedTargetList;
}
- (NSArray *)expandedTargetsForS3Target:(Target *)theTarget error:(NSError **)error {
    S3Service *s3 = [theTarget s3:error];
    if (s3 == nil) {
        return nil;
    }
    NSArray *s3BucketNames = [s3 s3BucketNamesWithTargetConnectionDelegate:nil error:error];
    if (s3BucketNames == nil) {
        return nil;
    }
    HSLogDebug(@"s3BucketNames for %@: %@", theTarget, s3BucketNames);
    
    NSURL *originalEndpoint = [theTarget endpoint];
    NSMutableArray *ret = [NSMutableArray array];
    
    for (NSString *s3BucketName in s3BucketNames) {
        NSURL *endpoint = nil;
        if ([theTarget targetType] == kTargetAWS) {
            NSString *location = [s3 locationOfS3Bucket:s3BucketName targetConnectionDelegate:nil error:error];
            if (location == nil) {
                return nil;
            }
            AWSRegion *awsRegion = [AWSRegion regionWithLocation:location];
            HSLogDebug(@"awsRegion for s3BucketName %@: %@", s3BucketName, location);
            
            NSURL *s3Endpoint = [awsRegion s3EndpointWithSSL:YES];
            HSLogDebug(@"s3Endpoint: %@", s3Endpoint);
            endpoint = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@@%@/%@", [originalEndpoint user], [s3Endpoint host], s3BucketName]];
        } else {
            endpoint = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@@%@/%@", [originalEndpoint scheme], [originalEndpoint user], [originalEndpoint host], s3BucketName]];
        }
        HSLogDebug(@"endpoint: %@", endpoint);
        
        Target *theTarget = [[[Target alloc] initWithEndpoint:endpoint secret:[theTarget secret:NULL] passphrase:[theTarget passphrase:NULL]] autorelease];
        [ret addObject:theTarget];
    }
    return ret;
}

- (BOOL)listBucketsForComputerUUID:(NSString *)theComputerUUID encryptionPassword:(NSString *)theEncryptionPassword error:(NSError **)error {
    NSArray *buckets = [Bucket bucketsWithTarget:target computerUUID:theComputerUUID encryptionPassword:theEncryptionPassword targetConnectionDelegate:nil error:error];
    if (buckets == nil) {
        return NO;
    }
    
    printf("target   %s\n", [[target endpointDisplayName] UTF8String]);
    printf("computer %s\n", [theComputerUUID UTF8String]);
    
    for (Bucket *bucket in buckets) {
        printf("\tfolder %s\n", [[bucket localPath] UTF8String]);
        printf("\t\tuuid %s\n", [[bucket bucketUUID] UTF8String]);
        
    }
    
    return YES;
}
- (BOOL)restoreComputerUUID:(NSString *)theComputerUUID bucketUUID:(NSString *)theBucketUUID encryptionPassword:(NSString *)theEncryptionPassword error:(NSError **)error {
    Bucket *myBucket = nil;
    NSArray *expandedTargetList = [self expandedTargetList:error];
    if (expandedTargetList == nil) {
        return NO;
    }
    for (Target *theTarget in expandedTargetList) {
        NSArray *buckets = [Bucket bucketsWithTarget:theTarget computerUUID:theComputerUUID encryptionPassword:theEncryptionPassword targetConnectionDelegate:nil error:error];
        if (buckets == nil) {
            return NO;
        }
        for (Bucket *bucket in buckets) {
            if ([[bucket bucketUUID] isEqualToString:theBucketUUID]) {
                myBucket = bucket;
                break;
            }
        }
        
        if (myBucket != nil) {
            break;
        }
    }
    if (myBucket == nil) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"folder %@ not found", theBucketUUID);
        return NO;
    }
    
    Repo *repo = [[[Repo alloc] initWithBucket:myBucket encryptionPassword:theEncryptionPassword targetUID:getuid() targetGID:getgid() loadExistingMutablePackFiles:NO targetConnectionDelegate:nil repoDelegate:nil error:error] autorelease];
    if (repo == nil) {
        return NO;
    }
    
    
    BlobKey *commitBlobKey = [repo headBlobKey:error];
    if (commitBlobKey == nil) {
        return NO;
    }
    
    printf("target   %s\n", [[[myBucket target] endpointDisplayName] UTF8String]);
    printf("computer %s\n", [[myBucket computerUUID] UTF8String]);
    printf("\nrestoring folder   %s\n\n", [[myBucket localPath] UTF8String]);
    
    return YES;
}

@end
