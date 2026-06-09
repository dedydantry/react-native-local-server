#import "LocalServer.h"
#import <React/RCTLog.h>
#import <GCDWebServer/GCDWebServer.h>
#import <GCDWebServer/GCDWebServerDataRequest.h>
#import <GCDWebServer/GCDWebServerDataResponse.h>
#import <GCDWebServer/GCDWebServerFileResponse.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

@interface LocalServer ()
@property (nonatomic, strong) GCDWebServer *webServer;
@property (nonatomic, strong) NSString *rootPath;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, strong) NSString *serverURL;
@property (nonatomic, strong) NSString *pingMessage;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, assign) BOOL hasListeners;
@property (nonatomic, assign) NSUInteger requestCounter;
@end

@implementation LocalServer

RCT_EXPORT_MODULE()

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.localserver.gcdwebserver.state", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

#pragma mark - RCTEventEmitter

- (NSArray<NSString *> *)supportedEvents {
    return @[@"LocalServerRequest"];
}

- (void)startObserving {
    self.hasListeners = YES;
}

- (void)stopObserving {
    self.hasListeners = NO;
}

- (void)emitRequestEvent:(NSDictionary *)payload {
    if (self.hasListeners) {
        [self sendEventWithName:@"LocalServerRequest" body:payload];
    }
}

#pragma mark - POST body helpers

- (BOOL)isTextContentType:(NSString *)ct {
    // Default unknown/missing → binary (file), so arbitrary bytes are never UTF-8 corrupted.
    if (ct.length == 0) return NO;
    NSString *c = [ct lowercaseString];
    return [c hasPrefix:@"text/"] || [c containsString:@"application/json"]
        || [c containsString:@"+json"] || [c containsString:@"application/x-www-form-urlencoded"];
}

- (BOOL)isJsonContentType:(NSString *)ct {
    if (ct.length == 0) return NO;
    NSString *c = [ct lowercaseString];
    return [c containsString:@"application/json"] || [c containsString:@"+json"];
}

- (NSString *)extensionForContentType:(NSString *)ct {
    if (ct.length == 0) return @".bin";
    NSString *c = [ct lowercaseString];
    if ([c containsString:@"jpeg"] || [c containsString:@"jpg"]) return @".jpg";
    if ([c containsString:@"png"]) return @".png";
    if ([c containsString:@"gif"]) return @".gif";
    if ([c containsString:@"webp"]) return @".webp";
    if ([c containsString:@"heic"]) return @".heic";
    if ([c containsString:@"pdf"]) return @".pdf";
    if ([c containsString:@"json"]) return @".json";
    if ([c hasPrefix:@"text/"]) return @".txt";
    return @".bin";
}

- (void)initializeGCDWebServerOnMainThread:(dispatch_block_t)completion {
    dispatch_block_t initializeAndContinue = ^{
        [GCDWebServer class];
        if (completion) {
            completion();
        }
    };

    if ([NSThread isMainThread]) {
        initializeAndContinue();
        return;
    }

    dispatch_async(dispatch_get_main_queue(), initializeAndContinue);
}

#pragma mark - IP Address Helper

- (NSString *)getWiFiIPAddress {
    NSString *address = @"127.0.0.1";
    struct ifaddrs *interfaces = NULL;

    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *temp = interfaces; temp != NULL; temp = temp->ifa_next) {
            if (!temp->ifa_addr || temp->ifa_addr->sa_family != AF_INET) {
                continue;
            }

            NSString *interfaceName = [NSString stringWithUTF8String:temp->ifa_name];
            BOOL isWiFi = [interfaceName isEqualToString:@"en0"] || [interfaceName isEqualToString:@"en1"];
            BOOL isUsable = (temp->ifa_flags & IFF_UP) && !(temp->ifa_flags & IFF_LOOPBACK);

            if (isWiFi && isUsable) {
                address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp->ifa_addr)->sin_addr)];
                break;
            }
        }
    }

    if (interfaces) {
        freeifaddrs(interfaces);
    }
    return address;
}

#pragma mark - MIME and Response Helpers

- (NSDictionary<NSString *, NSString *> *)mimeTypeOverrides {
    static NSDictionary *mimeTypes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mimeTypes = @{
            @"png": @"image/png",
            @"jpg": @"image/jpeg",
            @"jpeg": @"image/jpeg",
            @"gif": @"image/gif",
            @"webp": @"image/webp",
            @"svg": @"image/svg+xml",
            @"ico": @"image/x-icon",
            @"bmp": @"image/bmp",
            @"tiff": @"image/tiff",
            @"tif": @"image/tiff",
            @"heic": @"image/heic",
            @"heif": @"image/heif",
            @"html": @"text/html; charset=utf-8",
            @"htm": @"text/html; charset=utf-8",
            @"css": @"text/css; charset=utf-8",
            @"js": @"application/javascript; charset=utf-8",
            @"json": @"application/json; charset=utf-8",
            @"xml": @"application/xml; charset=utf-8",
            @"txt": @"text/plain; charset=utf-8",
            @"csv": @"text/csv; charset=utf-8",
            @"mp4": @"video/mp4",
            @"mov": @"video/quicktime",
            @"avi": @"video/x-msvideo",
            @"webm": @"video/webm",
            @"mp3": @"audio/mpeg",
            @"wav": @"audio/wav",
            @"ogg": @"audio/ogg",
            @"m4a": @"audio/mp4",
            @"pdf": @"application/pdf",
            @"zip": @"application/zip",
            @"woff": @"font/woff",
            @"woff2": @"font/woff2",
            @"ttf": @"font/ttf",
            @"otf": @"font/otf",
            @"eot": @"application/vnd.ms-fontobject",
        };
    });
    return mimeTypes;
}

- (NSString *)mimeTypeForPath:(NSString *)path {
    NSString *ext = [[path pathExtension] lowercaseString];
    return [self mimeTypeOverrides][ext] ?: @"application/octet-stream";
}

- (GCDWebServerResponse *)responseWithCORS:(GCDWebServerResponse *)response {
    [response setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
    [response setValue:@"GET, HEAD, POST, OPTIONS" forAdditionalHeader:@"Access-Control-Allow-Methods"];
    [response setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Headers"];
    return response;
}

- (GCDWebServerDataResponse *)jsonResponse:(NSDictionary *)object statusCode:(NSInteger)statusCode {
    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithJSONObject:object
                                                                              contentType:@"application/json; charset=utf-8"];
    response.statusCode = statusCode;
    return (GCDWebServerDataResponse *)[self responseWithCORS:response];
}

- (GCDWebServerDataResponse *)htmlResponse:(NSString *)html statusCode:(NSInteger)statusCode {
    NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithData:data
                                                                        contentType:@"text/html; charset=utf-8"];
    response.statusCode = statusCode;
    return (GCDWebServerDataResponse *)[self responseWithCORS:response];
}

- (GCDWebServerResponse *)notFoundResponse {
    return [self htmlResponse:@"<html><body><h1>404 Not Found</h1></body></html>" statusCode:404];
}

#pragma mark - Path Helpers

- (NSString *)safeFullPathForRequestPath:(NSString *)requestPath {
    NSString *decodedPath = [requestPath stringByRemovingPercentEncoding] ?: requestPath ?: @"/";
    NSString *relativePath = decodedPath;

    if ([relativePath hasPrefix:@"/"]) {
        relativePath = [relativePath substringFromIndex:1];
    }

    relativePath = [relativePath stringByStandardizingPath];
    if ([relativePath isEqualToString:@"."]) {
        relativePath = @"";
    }
    if ([relativePath hasPrefix:@".."] || [relativePath containsString:@"/../"]) {
        return nil;
    }

    NSString *standardRoot = [self.rootPath stringByStandardizingPath];
    NSString *candidate = [[standardRoot stringByAppendingPathComponent:relativePath] stringByStandardizingPath];

    if (![candidate isEqualToString:standardRoot] && ![candidate hasPrefix:[standardRoot stringByAppendingString:@"/"]]) {
        return nil;
    }

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:candidate];
    if (exists) {
        NSString *resolvedRoot = [standardRoot stringByResolvingSymlinksInPath];
        NSString *resolvedCandidate = [candidate stringByResolvingSymlinksInPath];
        if (![resolvedCandidate isEqualToString:resolvedRoot] &&
            ![resolvedCandidate hasPrefix:[resolvedRoot stringByAppendingString:@"/"]]) {
            return nil;
        }
    }

    return candidate;
}

- (NSString *)urlEncodedPath:(NSString *)relativePath {
    NSString *encoded = [relativePath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    return encoded ?: relativePath;
}

- (NSString *)htmlEscapedString:(NSString *)string {
    NSMutableString *escaped = [string mutableCopy] ?: [NSMutableString string];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"'" withString:@"&#39;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

#pragma mark - File and Directory Responses

- (GCDWebServerResponse *)fileResponseForPath:(NSString *)filePath request:(GCDWebServerRequest *)request attachment:(BOOL)attachment {
    if (!filePath) {
        return [self notFoundResponse];
    }

    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath isDirectory:&isDir] || isDir) {
        return [self notFoundResponse];
    }

    NSRange range = [request hasByteRange] ? request.byteRange : NSMakeRange(NSUIntegerMax, 0);
    GCDWebServerFileResponse *response = [[GCDWebServerFileResponse alloc] initWithFile:filePath
                                                                              byteRange:range
                                                                           isAttachment:attachment
                                                                       mimeTypeOverrides:[self mimeTypeOverrides]];
    if (!response) {
        return [self notFoundResponse];
    }

    // Revalidate instead of caching for a year: GCDWebServer emits an ETag/Last-Modified and
    // answers If-None-Match with 304, so clients still skip re-downloading unchanged files —
    // but an edited photo re-exported to the same path is never served stale.
    response.cacheControlMaxAge = 0;
    [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
    return [self responseWithCORS:response];
}

- (GCDWebServerResponse *)directoryListingForPath:(NSString *)dirPath requestPath:(NSString *)requestPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [[fm contentsOfDirectoryAtPath:dirPath error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'>"];
    [html appendString:@"<style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:20px;background:#1a1a2e;color:#fff}"];
    [html appendString:@"a{color:#818cf8;text-decoration:none;display:block;padding:8px 0}a:hover{text-decoration:underline}</style>"];
    [html appendFormat:@"</head><body><h2>Index of %@</h2>", [self htmlEscapedString:requestPath ?: @"/"]];

    if (![requestPath isEqualToString:@"/"]) {
        [html appendString:@"<a href='../'>../</a>"];
    }

    for (NSString *item in contents) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];

        NSString *escapedName = [self htmlEscapedString:item];
        NSString *encodedName = [self urlEncodedPath:item];

        if (isDir) {
            [html appendFormat:@"<a href='%@/'>[dir] %@/</a>", encodedName, escapedName];
        } else {
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long fileSize = [attrs fileSize];
            NSString *sizeStr = nil;
            if (fileSize < 1024) {
                sizeStr = [NSString stringWithFormat:@"%llu B", fileSize];
            } else if (fileSize < 1024 * 1024) {
                sizeStr = [NSString stringWithFormat:@"%.1f KB", fileSize / 1024.0];
            } else {
                sizeStr = [NSString stringWithFormat:@"%.1f MB", fileSize / (1024.0 * 1024.0)];
            }
            [html appendFormat:@"<a href='%@'>[file] %@ <small style='color:#888'>(%@)</small></a>", encodedName, escapedName, sizeStr];
        }
    }

    [html appendString:@"</body></html>"];
    return [self htmlResponse:html statusCode:200];
}

- (GCDWebServerResponse *)staticResponseForRequest:(GCDWebServerRequest *)request {
    NSString *requestPath = request.path ?: @"/";
    NSString *fullPath = [self safeFullPathForRequestPath:requestPath];
    if (!fullPath) {
        return [self notFoundResponse];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:fullPath isDirectory:&isDir];
    if (!exists) {
        return [self notFoundResponse];
    }

    if (isDir) {
        NSString *indexPath = [fullPath stringByAppendingPathComponent:@"index.html"];
        BOOL indexIsDir = NO;
        if ([fm fileExistsAtPath:indexPath isDirectory:&indexIsDir] && !indexIsDir) {
            return [self fileResponseForPath:indexPath request:request attachment:NO];
        }
        return [self directoryListingForPath:fullPath requestPath:requestPath];
    }

    return [self fileResponseForPath:fullPath request:request attachment:NO];
}

#pragma mark - JSON API Responses

- (void)collectFilesInDirectory:(NSString *)dirPath relativeTo:(NSString *)basePath into:(NSMutableArray *)results serverURL:(NSString *)serverURL {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:nil];

    for (NSString *item in contents) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];

        if (isDir) {
            [self collectFilesInDirectory:fullPath relativeTo:basePath into:results serverURL:serverURL];
            continue;
        }

        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        NSDate *modDate = [attrs fileModificationDate];
        NSString *relativePath = @"";

        if (fullPath.length > basePath.length) {
            relativePath = [fullPath substringFromIndex:basePath.length];
            if ([relativePath hasPrefix:@"/"]) {
                relativePath = [relativePath substringFromIndex:1];
            }
        }

        NSString *encodedPath = [self urlEncodedPath:relativePath];
        NSString *downloadURL = [NSString stringWithFormat:@"%@/download/%@", serverURL ?: @"", encodedPath];
        NSMutableDictionary *fileInfo = [NSMutableDictionary dictionary];
        fileInfo[@"name"] = item;
        fileInfo[@"path"] = relativePath;
        fileInfo[@"url"] = downloadURL;
        fileInfo[@"size"] = @([attrs fileSize]);
        fileInfo[@"mime"] = [self mimeTypeForPath:fullPath];
        fileInfo[@"ext"] = [[fullPath pathExtension] lowercaseString] ?: @"";
        if (modDate) {
            fileInfo[@"modified"] = @([modDate timeIntervalSince1970] * 1000);
        }

        [results addObject:fileInfo];
    }
}

- (GCDWebServerResponse *)filesJSONResponse {
    NSMutableArray *files = [NSMutableArray array];
    [self collectFilesInDirectory:self.rootPath relativeTo:self.rootPath into:files serverURL:self.serverURL];

    return [self jsonResponse:@{
        @"success": @(YES),
        @"root": self.rootPath ?: @"",
        @"server": self.serverURL ?: @"",
        @"total": @(files.count),
        @"files": files
    } statusCode:200];
}

- (GCDWebServerResponse *)directoryJSONForPath:(NSString *)relativeDirPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *apiPath = relativeDirPath.length > 0 ? relativeDirPath : @"/";
    NSString *targetPath = [self safeFullPathForRequestPath:apiPath];

    BOOL isDir = NO;
    if (!targetPath || ![fm fileExistsAtPath:targetPath isDirectory:&isDir] || !isDir) {
        return [self jsonResponse:@{
            @"success": @(NO),
            @"error": @"Directory not found",
            @"path": apiPath ?: @"/"
        } statusCode:404];
    }

    NSArray *contents = [[fm contentsOfDirectoryAtPath:targetPath error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray *items = [NSMutableArray array];

    for (NSString *itemName in contents) {
        NSString *fullItemPath = [targetPath stringByAppendingPathComponent:itemName];
        BOOL itemIsDir = NO;
        [fm fileExistsAtPath:fullItemPath isDirectory:&itemIsDir];

        NSDictionary *attrs = [fm attributesOfItemAtPath:fullItemPath error:nil];
        NSDate *modDate = [attrs fileModificationDate];
        NSString *itemRelativePath = @"";

        if (fullItemPath.length > self.rootPath.length) {
            itemRelativePath = [fullItemPath substringFromIndex:self.rootPath.length];
            if ([itemRelativePath hasPrefix:@"/"]) {
                itemRelativePath = [itemRelativePath substringFromIndex:1];
            }
        }

        NSMutableDictionary *itemInfo = [NSMutableDictionary dictionary];
        itemInfo[@"name"] = itemName;
        itemInfo[@"path"] = itemRelativePath;

        if (itemIsDir) {
            NSArray *children = [fm contentsOfDirectoryAtPath:fullItemPath error:nil];
            itemInfo[@"type"] = @"directory";
            itemInfo[@"children"] = @(children ? children.count : 0);
        } else {
            NSString *encodedPath = [self urlEncodedPath:itemRelativePath];
            itemInfo[@"type"] = @"file";
            itemInfo[@"size"] = @([attrs fileSize]);
            itemInfo[@"mime"] = [self mimeTypeForPath:fullItemPath];
            itemInfo[@"ext"] = [[fullItemPath pathExtension] lowercaseString] ?: @"";
            itemInfo[@"url"] = [NSString stringWithFormat:@"%@/%@", self.serverURL ?: @"", encodedPath];
            itemInfo[@"download"] = [NSString stringWithFormat:@"%@/download/%@", self.serverURL ?: @"", encodedPath];
        }

        if (modDate) {
            itemInfo[@"modified"] = @([modDate timeIntervalSince1970] * 1000);
        }

        [items addObject:itemInfo];
    }

    return [self jsonResponse:@{
        @"success": @(YES),
        @"path": apiPath ?: @"/",
        @"server": self.serverURL ?: @"",
        @"total": @(items.count),
        @"items": items
    } statusCode:200];
}

#pragma mark - Server Configuration

- (void)configureWebServer:(GCDWebServer *)server {
    __weak typeof(self) weakSelf = self;

    [server addDefaultHandlerForMethod:@"GET"
                          requestClass:[GCDWebServerRequest class]
                          processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [weakSelf staticResponseForRequest:request];
    }];

    [server addHandlerForMethod:@"GET"
                      pathRegex:@"/ping/?"
                   requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        return [strongSelf jsonResponse:@{
            @"status": @(YES),
            @"message": strongSelf.pingMessage ?: @"pong"
        } statusCode:200];
    }];

    [server addHandlerForMethod:@"GET"
                      pathRegex:@"/api/files/?"
                   requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [weakSelf filesJSONResponse];
    }];

    [server addHandlerForMethod:@"GET"
                      pathRegex:@"/api/dir/?"
                   requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [weakSelf directoryJSONForPath:@"/"];
    }];

    [server addHandlerForMethod:@"GET"
                      pathRegex:@"/api/dir/.*"
                   requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSString *path = request.path.length > 9 ? [request.path substringFromIndex:9] : @"/";
        return [weakSelf directoryJSONForPath:path];
    }];

    [server addHandlerForMethod:@"GET"
                      pathRegex:@"/download/.*"
                   requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSString *path = request.path.length > 10 ? [request.path substringFromIndex:10] : @"";
        NSString *filePath = [weakSelf safeFullPathForRequestPath:path];
        return [weakSelf fileResponseForPath:filePath request:request attachment:YES];
    }];

    [server addHandlerForMethod:@"POST"
                           path:@"/global-post"
                   requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [weakSelf handleGlobalPost:(GCDWebServerDataRequest *)request];
    }];

    [server addDefaultHandlerForMethod:@"OPTIONS"
                          requestClass:[GCDWebServerRequest class]
                          processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        GCDWebServerResponse *response = [GCDWebServerResponse responseWithStatusCode:204];
        return [weakSelf responseWithCORS:response];
    }];
}

#pragma mark - POST /global-post

- (GCDWebServerResponse *)handleGlobalPost:(GCDWebServerDataRequest *)request {
    NSString *contentType = request.contentType ?: @"";
    NSData *data = request.data ?: [NSData data];

    self.requestCounter += 1;
    NSString *requestId = [NSString stringWithFormat:@"post-%.0f-%lu",
                           [[NSDate date] timeIntervalSince1970] * 1000.0,
                           (unsigned long)self.requestCounter];

    BOOL isText = [self isTextContentType:contentType];
    BOOL asFile = !isText || data.length > (8 * 1024 * 1024);

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"requestId"] = requestId;
    payload[@"path"] = @"/global-post";
    payload[@"method"] = @"POST";
    payload[@"contentType"] = contentType;
    payload[@"query"] = request.URL.query ?: @"";
    payload[@"size"] = @(data.length);

    // Best-effort full headers (lowercase keys) for parity with Android.
    // GCDWebServerRequest has no public all-headers accessor, so fall back to a known subset.
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSDictionary *allHeaders = nil;
    @try {
        id raw = [request valueForKey:@"headers"];
        if ([raw isKindOfClass:[NSDictionary class]]) {
            allHeaders = raw;
        }
    } @catch (__unused NSException *e) {}

    if (allHeaders) {
        [allHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
            if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]]) {
                headers[[k lowercaseString]] = v;
            }
        }];
    } else {
        if (contentType.length > 0) headers[@"content-type"] = contentType;
        headers[@"content-length"] = @(data.length).stringValue;
    }
    payload[@"headers"] = headers;

    if (asFile) {
        NSString *ext = [self extensionForContentType:contentType];
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"global-post"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *filePath = [dir stringByAppendingPathComponent:[requestId stringByAppendingString:ext]];
        [data writeToFile:filePath atomically:YES];
        payload[@"bodyType"] = @"file";
        payload[@"filePath"] = filePath;
    } else {
        NSString *bodyString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        payload[@"bodyType"] = [self isJsonContentType:contentType] ? @"json" : @"text";
        payload[@"body"] = bodyString;
    }

    [self emitRequestEvent:payload];

    return [self jsonResponse:@{ @"success": @(YES), @"requestId": requestId } statusCode:200];
}

#pragma mark - Server Control

RCT_EXPORT_METHOD(start:(nonnull NSNumber *)port
                  root:(NSString *)root
                  localOnly:(BOOL)localOnly
                  pingMessage:(NSString *)pingMessage
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [self initializeGCDWebServerOnMainThread:^{
        dispatch_async(self.stateQueue, ^{
            if (self.webServer.isRunning && self.serverURL) {
                resolve(self.serverURL);
                return;
            }

            [self forceCleanupLocked];

            NSString *normalizedRoot = root;
            if ([root hasPrefix:@"file://"]) {
                normalizedRoot = [[NSURL URLWithString:root] path];
            }

            BOOL isDir = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:normalizedRoot isDirectory:&isDir] || !isDir) {
                reject(@"INVALID_ROOT", [NSString stringWithFormat:@"Root directory does not exist: %@", normalizedRoot], nil);
                return;
            }

            self.rootPath = [normalizedRoot stringByStandardizingPath];
            self.port = [port integerValue];
            self.pingMessage = (pingMessage && pingMessage.length > 0) ? pingMessage : @"pong";

            GCDWebServer *server = [[GCDWebServer alloc] init];
            [self configureWebServer:server];

            NSMutableDictionary *options = [@{
                GCDWebServerOption_Port: @(self.port),
                GCDWebServerOption_BindToLocalhost: @(localOnly),
                GCDWebServerOption_MaxPendingConnections: @(128),
                GCDWebServerOption_AutomaticallyMapHEADToGET: @(YES),
                GCDWebServerOption_ConnectedStateCoalescingInterval: @(0.25),
                GCDWebServerOption_ServerName: @"LemonBoothLocalServer"
            } mutableCopy];

#if TARGET_OS_IPHONE
            options[GCDWebServerOption_AutomaticallySuspendInBackground] = @(NO);
#endif

            NSError *error = nil;
            if (![server startWithOptions:options error:&error]) {
                NSString *message = error.localizedDescription ?: @"Failed to start local server";
                reject(@"START_ERROR", message, error);
                return;
            }

            self.webServer = server;
            NSUInteger actualPort = server.port > 0 ? server.port : (NSUInteger)self.port;
            NSString *ipAddress = localOnly ? @"127.0.0.1" : [self getWiFiIPAddress];
            self.serverURL = [NSString stringWithFormat:@"http://%@:%lu", ipAddress, (unsigned long)actualPort];

            RCTLogInfo(@"[LocalServer] Started at %@, serving: %@", self.serverURL, self.rootPath);
            resolve(self.serverURL);
        });
    }];
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    dispatch_async(self.stateQueue, ^{
        [self forceCleanupLocked];
        RCTLogInfo(@"[LocalServer] Stopped");
        resolve(@(YES));
    });
}

RCT_EXPORT_METHOD(isRunning:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    dispatch_async(self.stateQueue, ^{
        resolve(@(self.webServer && self.webServer.isRunning));
    });
}

RCT_EXPORT_METHOD(getIPAddress:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    resolve([self getWiFiIPAddress]);
}

- (void)forceCleanupLocked {
    if (self.webServer) {
        [self.webServer stop];
        self.webServer = nil;
    }
    self.serverURL = nil;
}

- (void)dealloc {
    dispatch_sync(self.stateQueue, ^{
        [self forceCleanupLocked];
    });
}

@end
