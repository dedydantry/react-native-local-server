#import "LocalServer.h"
#import <React/RCTLog.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/socket.h>
#import <netinet/tcp.h>  // Add this for TCP_NODELAY

// Pure BSD socket-based HTTP static file server
// Streams large files in chunks to handle images/videos of any size

#define MAX_CONCURRENT_CONNECTIONS 64
#define LISTEN_BACKLOG 1024
#define KEEPALIVE_TIMEOUT 30  // increased from 15
#define KEEPALIVE_MAX_REQUESTS 100
#define CHUNK_SIZE (128 * 1024)  // 512KB chunks for better throughput
#define SEND_BUFFER_SIZE (1024 * 1024)  // 1MB send buffer
#define RECV_BUFFER_SIZE (64 * 1024)    // 64KB recv buffer

@interface LocalServer ()
@property (nonatomic, strong) dispatch_source_t serverSource;
@property (nonatomic, assign) int serverSocket;
@property (nonatomic, strong) NSString *rootPath;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, assign) BOOL isServerRunning;
@property (nonatomic, strong) NSString *serverURL;
@property (nonatomic, strong) NSString *pingMessage;
@property (nonatomic, strong) dispatch_queue_t serverQueue;
@property (nonatomic, assign) dispatch_semaphore_t connectionSemaphore;
@end

@implementation LocalServer

RCT_EXPORT_MODULE()

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _isServerRunning = NO;
        _serverQueue = dispatch_queue_create("com.localserver.queue", DISPATCH_QUEUE_CONCURRENT);
        _connectionSemaphore = dispatch_semaphore_create(MAX_CONCURRENT_CONNECTIONS);
    }
    return self;
}

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

#pragma mark - IP Address Helper

- (NSString *)getWiFiIPAddress {
    NSString *address = @"127.0.0.1";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    
    success = getifaddrs(&interfaces);
    if (success == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                // Check for WiFi adapter
                NSString *interfaceName = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([interfaceName isEqualToString:@"en0"] || [interfaceName isEqualToString:@"en1"]) {
                    // Check if interface is up and not loopback
                    if ((temp_addr->ifa_flags & IFF_UP) && !(temp_addr->ifa_flags & IFF_LOOPBACK)) {
                        address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    }
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    freeifaddrs(interfaces);
    return address;
}

#pragma mark - MIME Type Helper

- (NSString *)mimeTypeForPath:(NSString *)path {
    NSString *ext = [[path pathExtension] lowercaseString];
    
    static NSDictionary *mimeTypes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mimeTypes = @{
            // Images
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
            // Web
            @"html": @"text/html; charset=utf-8",
            @"htm": @"text/html; charset=utf-8",
            @"css": @"text/css; charset=utf-8",
            @"js": @"application/javascript; charset=utf-8",
            @"json": @"application/json; charset=utf-8",
            @"xml": @"application/xml; charset=utf-8",
            @"txt": @"text/plain; charset=utf-8",
            @"csv": @"text/csv; charset=utf-8",
            // Video
            @"mp4": @"video/mp4",
            @"mov": @"video/quicktime",
            @"avi": @"video/x-msvideo",
            @"webm": @"video/webm",
            // Audio
            @"mp3": @"audio/mpeg",
            @"wav": @"audio/wav",
            @"ogg": @"audio/ogg",
            @"m4a": @"audio/mp4",
            // Documents
            @"pdf": @"application/pdf",
            @"zip": @"application/zip",
            @"woff": @"font/woff",
            @"woff2": @"font/woff2",
            @"ttf": @"font/ttf",
            @"otf": @"font/otf",
            @"eot": @"application/vnd.ms-fontobject",
        };
    });
    
    NSString *mimeType = mimeTypes[ext];
    return mimeType ?: @"application/octet-stream";
}

#pragma mark - HTTP Response Builder

- (NSData *)buildHTTPHeaders:(NSInteger)statusCode
                  statusText:(NSString *)statusText
                 contentType:(NSString *)contentType
               contentLength:(unsigned long long)contentLength
                extraHeaders:(NSDictionary *)extraHeaders
                   keepAlive:(BOOL)keepAlive {
    
    NSMutableString *header = [NSMutableString string];
    [header appendFormat:@"HTTP/1.1 %ld %@\r\n", (long)statusCode, statusText];
    [header appendFormat:@"Content-Type: %@\r\n", contentType];
    [header appendFormat:@"Content-Length: %llu\r\n", contentLength];
    if (keepAlive) {
        [header appendString:@"Connection: keep-alive\r\n"];
        [header appendFormat:@"Keep-Alive: timeout=%d, max=%d\r\n", KEEPALIVE_TIMEOUT, KEEPALIVE_MAX_REQUESTS];
    } else {
        [header appendString:@"Connection: close\r\n"];
    }
    [header appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [header appendString:@"Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"];
    [header appendString:@"Access-Control-Allow-Headers: *\r\n"];
    [header appendString:@"Cache-Control: no-cache\r\n"];
    
    if (extraHeaders) {
        for (NSString *key in extraHeaders) {
            [header appendFormat:@"%@: %@\r\n", key, extraHeaders[key]];
        }
    }
    
    [header appendString:@"\r\n"];
    
    return [header dataUsingEncoding:NSUTF8StringEncoding];
}

- (BOOL)sendData:(NSData *)data toSocket:(int)sock {
    const uint8_t *bytes = (const uint8_t *)[data bytes];
    NSUInteger remaining = [data length];
    NSUInteger offset = 0;
    int retryCount = 0;
    const int maxRetries = 100;  // Max retries for EAGAIN
    
    while (remaining > 0) {
        ssize_t sent = send(sock, bytes + offset, remaining, 0);
        if (sent > 0) {
            offset += sent;
            remaining -= sent;
            retryCount = 0;  // Reset retry counter on success
        } else if (sent == -1) {
            if (errno == EINTR) {
                continue; // Interrupted, retry immediately
            } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
                retryCount++;
                if (retryCount >= maxRetries) {
                    RCTLogInfo(@"[LocalServer] Send timeout after %d retries", retryCount);
                    return NO;
                }
                // Socket buffer full, wait with exponential backoff
                usleep(1000 * MIN(retryCount, 10)); // 1ms to 10ms
                continue;
            } else {
                // Real error (EPIPE, ECONNRESET, etc.)
                RCTLogInfo(@"[LocalServer] Send error: %s (errno=%d)", strerror(errno), errno);
                return NO;
            }
        } else {
            return NO; // sent == 0, connection closed
        }
    }
    return YES;
}

- (void)sendHTTPResponse:(NSInteger)statusCode
              statusText:(NSString *)statusText
             contentType:(NSString *)contentType
                    body:(NSData *)body
            extraHeaders:(NSDictionary *)extraHeaders
                toSocket:(int)sock
               keepAlive:(BOOL)keepAlive {
    
    NSData *headers = [self buildHTTPHeaders:statusCode
                                 statusText:statusText
                                contentType:contentType
                              contentLength:body.length
                               extraHeaders:extraHeaders
                                  keepAlive:keepAlive];
    [self sendData:headers toSocket:sock];
    [self sendData:body toSocket:sock];
}

- (void)send404ToSocket:(int)sock keepAlive:(BOOL)keepAlive {
    NSString *body = @"<html><body><h1>404 Not Found</h1></body></html>";
    NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
    [self sendHTTPResponse:404 statusText:@"Not Found" contentType:@"text/html" body:bodyData extraHeaders:nil toSocket:sock keepAlive:keepAlive];
}

- (void)sendFileAtPath:(NSString *)filePath toSocket:(int)sock keepAlive:(BOOL)keepAlive {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
    unsigned long long fileSize = [attrs fileSize];
    
    if (fileSize == 0) {
        [self send404ToSocket:sock keepAlive:keepAlive];
        return;
    }
    
    NSString *mimeType = [self mimeTypeForPath:filePath];
    
    // For large files (>1MB), add Accept-Ranges header for potential resume support
    NSMutableDictionary *extraHeaders = [NSMutableDictionary dictionary];
    if (fileSize > 1024 * 1024) {
        extraHeaders[@"Accept-Ranges"] = @"bytes";
    }
    
    // Send headers first
    NSData *headers = [self buildHTTPHeaders:200
                                 statusText:@"OK"
                                contentType:mimeType
                              contentLength:fileSize
                               extraHeaders:extraHeaders.count > 0 ? extraHeaders : nil
                                  keepAlive:keepAlive];
    if (![self sendData:headers toSocket:sock]) {
        RCTLogInfo(@"[LocalServer] Failed to send headers for %@", filePath);
        return;
    }
    
    // Use file descriptor for more efficient reading (avoids NSFileHandle overhead)
    int fd = open([filePath fileSystemRepresentation], O_RDONLY);
    if (fd < 0) {
        RCTLogInfo(@"[LocalServer] Failed to open file: %@", filePath);
        return;
    }
    
    // Advise kernel we'll read sequentially
    fcntl(fd, F_RDAHEAD, 1);
    
    // Stream file in large chunks
    uint8_t *buffer = malloc(CHUNK_SIZE);
    if (!buffer) {
        close(fd);
        return;
    }
    
    unsigned long long totalSent = 0;
    BOOL success = YES;
    
    while (totalSent < fileSize) {
        @autoreleasepool {
            ssize_t bytesRead = read(fd, buffer, CHUNK_SIZE);
            if (bytesRead <= 0) {
                if (bytesRead < 0) {
                    RCTLogInfo(@"[LocalServer] Read error: %s", strerror(errno));
                }
                break; // EOF or error
            }
            
            NSData *chunk = [NSData dataWithBytesNoCopy:buffer length:bytesRead freeWhenDone:NO];
            if (![self sendData:chunk toSocket:sock]) {
                RCTLogInfo(@"[LocalServer] Send failed at %llu/%llu bytes", totalSent, fileSize);
                success = NO;
                break;
            }
            
            totalSent += bytesRead;
        }
    }
    
    free(buffer);
    close(fd);
    
    if (success && totalSent == fileSize) {
        RCTLogInfo(@"[LocalServer] Sent %llu bytes for %@", totalSent, [filePath lastPathComponent]);
    }
}

- (NSData *)buildDirectoryListingResponse:(NSString *)dirPath requestPath:(NSString *)requestPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    
    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'>"];
    [html appendString:@"<style>body{font-family:-apple-system,sans-serif;padding:20px;background:#1a1a2e;color:#fff}"];
    [html appendString:@"a{color:#818cf8;text-decoration:none;display:block;padding:8px 0}a:hover{text-decoration:underline}</style>"];
    [html appendFormat:@"</head><body><h2>Index of %@</h2>", requestPath];
    
    if (![requestPath isEqualToString:@"/"]) {
        [html appendString:@"<a href='../'>..</a>"];
    }
    
    for (NSString *item in contents) {
        BOOL isDir;
        NSString *fullPath = [dirPath stringByAppendingPathComponent:item];
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];
        
        if (isDir) {
            [html appendFormat:@"<a href='%@/'>📁 %@/</a>", item, item];
        } else {
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long fileSize = [attrs fileSize];
            NSString *sizeStr;
            if (fileSize < 1024) {
                sizeStr = [NSString stringWithFormat:@"%llu B", fileSize];
            } else if (fileSize < 1024 * 1024) {
                sizeStr = [NSString stringWithFormat:@"%.1f KB", fileSize / 1024.0];
            } else {
                sizeStr = [NSString stringWithFormat:@"%.1f MB", fileSize / (1024.0 * 1024.0)];
            }
            [html appendFormat:@"<a href='%@'>📄 %@ <small style='color:#888'>(%@)</small></a>", item, item, sizeStr];
        }
    }
    
    [html appendString:@"</body></html>"];
    
    return [html dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - API: List All Files as JSON

- (void)collectFilesInDirectory:(NSString *)dirPath
                   relativeTo:(NSString *)basePath
                        into:(NSMutableArray *)results
                   serverURL:(NSString *)serverURL {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    
    for (NSString *item in contents) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];
        
        if (isDir) {
            // Recurse into subdirectories
            [self collectFilesInDirectory:fullPath relativeTo:basePath into:results serverURL:serverURL];
        } else {
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long fileSize = [attrs fileSize];
            NSDate *modDate = [attrs fileModificationDate];
            
            // Build relative path from root
            NSString *relativePath = @"";
            if (fullPath.length > basePath.length) {
                relativePath = [fullPath substringFromIndex:basePath.length];
                if ([relativePath hasPrefix:@"/"]) {
                    relativePath = [relativePath substringFromIndex:1];
                }
            }
            
            // URL-encode the relative path for the download link
            NSString *encodedPath = [relativePath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
            NSString *downloadURL = [NSString stringWithFormat:@"%@/download/%@", serverURL, encodedPath];
            NSString *mimeType = [self mimeTypeForPath:fullPath];
            NSString *ext = [[fullPath pathExtension] lowercaseString];
            
            NSMutableDictionary *fileInfo = [NSMutableDictionary dictionary];
            fileInfo[@"name"] = item;
            fileInfo[@"path"] = relativePath;
            fileInfo[@"url"] = downloadURL;
            fileInfo[@"size"] = @(fileSize);
            fileInfo[@"mime"] = mimeType;
            fileInfo[@"ext"] = ext ?: @"";
            if (modDate) {
                fileInfo[@"modified"] = @([modDate timeIntervalSince1970] * 1000); // ms timestamp
            }
            
            [results addObject:fileInfo];
        }
    }
}

- (NSData *)buildFilesJSONResponse {
    NSMutableArray *files = [NSMutableArray array];
    [self collectFilesInDirectory:self.rootPath relativeTo:self.rootPath into:files serverURL:self.serverURL];
    
    NSDictionary *response = @{
        @"success": @(YES),
        @"root": self.rootPath ?: @"",
        @"server": self.serverURL ?: @"",
        @"total": @(files.count),
        @"files": files
    };
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:&error];
    if (error) {
        NSString *errJSON = @"{\"success\":false,\"error\":\"Failed to serialize JSON\"}";
        return [errJSON dataUsingEncoding:NSUTF8StringEncoding];
    }
    return jsonData;
}

#pragma mark - API: List Directory Contents (non-recursive)

- (NSData *)buildDirectoryJSONForPath:(NSString *)relativeDirPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // Resolve the target directory
    NSString *targetPath;
    if (!relativeDirPath || [relativeDirPath length] == 0 || [relativeDirPath isEqualToString:@"/"]) {
        targetPath = self.rootPath;
        relativeDirPath = @"/";
    } else {
        // Sanitize — prevent traversal
        relativeDirPath = [relativeDirPath stringByStandardizingPath];
        if ([relativeDirPath hasPrefix:@".."]) {
            NSString *errJSON = @"{\"success\":false,\"error\":\"Invalid path\"}";
            return [errJSON dataUsingEncoding:NSUTF8StringEncoding];
        }
        // Remove leading slash for appending
        NSString *cleaned = relativeDirPath;
        if ([cleaned hasPrefix:@"/"]) {
            cleaned = [cleaned substringFromIndex:1];
        }
        targetPath = [self.rootPath stringByAppendingPathComponent:cleaned];
    }
    
    // Verify directory exists
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:targetPath isDirectory:&isDir] || !isDir) {
        NSString *errJSON = [NSString stringWithFormat:@"{\"success\":false,\"error\":\"Directory not found\",\"path\":\"%@\"}", relativeDirPath];
        return [errJSON dataUsingEncoding:NSUTF8StringEncoding];
    }
    
    NSArray *contents = [fm contentsOfDirectoryAtPath:targetPath error:nil];
    NSMutableArray *items = [NSMutableArray array];
    
    for (NSString *itemName in contents) {
        NSString *fullItemPath = [targetPath stringByAppendingPathComponent:itemName];
        BOOL itemIsDir = NO;
        [fm fileExistsAtPath:fullItemPath isDirectory:&itemIsDir];
        
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullItemPath error:nil];
        NSDate *modDate = [attrs fileModificationDate];
        
        // Build relative path from root
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
            itemInfo[@"type"] = @"directory";
            
            // Count children (shallow)
            NSArray *children = [fm contentsOfDirectoryAtPath:fullItemPath error:nil];
            itemInfo[@"children"] = @(children ? children.count : 0);
        } else {
            itemInfo[@"type"] = @"file";
            unsigned long long fileSize = [attrs fileSize];
            NSString *mimeType = [self mimeTypeForPath:fullItemPath];
            NSString *ext = [[fullItemPath pathExtension] lowercaseString];
            
            NSString *encodedPath = [itemRelativePath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
            NSString *fileURL = [NSString stringWithFormat:@"%@/%@", self.serverURL, encodedPath];
            NSString *downloadURL = [NSString stringWithFormat:@"%@/download/%@", self.serverURL, encodedPath];
            
            itemInfo[@"size"] = @(fileSize);
            itemInfo[@"mime"] = mimeType;
            itemInfo[@"ext"] = ext ?: @"";
            itemInfo[@"url"] = fileURL;
            itemInfo[@"download"] = downloadURL;
        }
        
        if (modDate) {
            itemInfo[@"modified"] = @([modDate timeIntervalSince1970] * 1000);
        }
        
        [items addObject:itemInfo];
    }
    
    NSDictionary *response = @{
        @"success": @(YES),
        @"path": relativeDirPath ?: @"/",
        @"server": self.serverURL ?: @"",
        @"total": @(items.count),
        @"items": items
    };
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:&error];
    if (error) {
        NSString *errJSON = @"{\"success\":false,\"error\":\"Failed to serialize JSON\"}";
        return [errJSON dataUsingEncoding:NSUTF8StringEncoding];
    }
    return jsonData;
}

#pragma mark - Request Parser

- (NSString *)parseRequestPath:(NSData *)requestData {
    NSString *request = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
    if (!request) return @"/";
    
    // Parse first line: "GET /path HTTP/1.1"
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) return @"/";
    
    NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
    if (parts.count < 2) return @"/";
    
    NSString *path = parts[1];
    
    // URL decode
    path = [path stringByRemovingPercentEncoding];
    
    // Remove query string
    NSRange queryRange = [path rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        path = [path substringToIndex:queryRange.location];
    }
    
    return path ?: @"/";
}

#pragma mark - Connection Handler

- (void)handleConnection:(int)clientSocket {
    // Set SO_NOSIGPIPE to prevent SIGPIPE crash when client disconnects
    int nosigpipe = 1;
    setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
    
    // Enable TCP_NODELAY for low latency (disable Nagle's algorithm)
    int nodelay = 1;
    setsockopt(clientSocket, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
    
    // Increase send buffer for large file transfers
    int sendBufSize = SEND_BUFFER_SIZE;
    setsockopt(clientSocket, SOL_SOCKET, SO_SNDBUF, &sendBufSize, sizeof(sendBufSize));
    
    // Increase recv buffer
    int recvBufSize = RECV_BUFFER_SIZE;
    setsockopt(clientSocket, SOL_SOCKET, SO_RCVBUF, &recvBufSize, sizeof(recvBufSize));
    
    // Set send/receive timeouts (60 seconds for large files)
    struct timeval timeout;
    timeout.tv_sec = 60;  // increased from 30
    timeout.tv_usec = 0;
    setsockopt(clientSocket, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    
    // Enable TCP keep-alive to detect dead connections
    int keepAliveOn = 1;
    setsockopt(clientSocket, SOL_SOCKET, SO_KEEPALIVE, &keepAliveOn, sizeof(keepAliveOn));
    
    int requestCount = 0;
    BOOL keepAlive = YES;
    
    // Keep-Alive loop: handle multiple requests on the same connection
    while (keepAlive && requestCount < KEEPALIVE_MAX_REQUESTS && self.isServerRunning) {
        
        // For subsequent requests, use shorter recv timeout (keep-alive idle timeout)
        if (requestCount > 0) {
            struct timeval kaTimeout;
            kaTimeout.tv_sec = KEEPALIVE_TIMEOUT;
            kaTimeout.tv_usec = 0;
            setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &kaTimeout, sizeof(kaTimeout));
        }
        
        // Read request (8KB buffer for headers)
        char buffer[8192];
        ssize_t bytesRead = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
        if (bytesRead <= 0) {
            break; // Client closed or timeout — exit loop
        }
        buffer[bytesRead] = '\0';
        requestCount++;
        
        NSData *requestData = [NSData dataWithBytes:buffer length:bytesRead];
        NSString *requestPath = [self parseRequestPath:requestData];
        RCTLogInfo(@"[LocalServer] Request #%d: %@", requestCount, requestPath);
        
        // Extract HTTP method and headers
        NSString *requestStr = [[NSString alloc] initWithBytes:buffer length:bytesRead encoding:NSUTF8StringEncoding];
        NSArray *requestLines = [requestStr componentsSeparatedByString:@"\r\n"];
        NSString *firstLine = requestLines.count > 0 ? requestLines[0] : @"";
        NSArray *firstLineParts = [firstLine componentsSeparatedByString:@" "];
        NSString *httpMethod = firstLineParts.count > 0 ? [firstLineParts[0] uppercaseString] : @"GET";
        
        // Check Connection header from client (HTTP/1.1 defaults to keep-alive)
        BOOL clientWantsKeepAlive = YES; // HTTP/1.1 default
        for (NSString *line in requestLines) {
            if ([[line lowercaseString] hasPrefix:@"connection:"]) {
                NSString *val = [[line substringFromIndex:11] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                clientWantsKeepAlive = ![[val lowercaseString] isEqualToString:@"close"];
                break;
            }
        }
        // Respect client preference; also force close on last allowed request
        keepAlive = clientWantsKeepAlive && (requestCount < KEEPALIVE_MAX_REQUESTS);
        
        // Handle OPTIONS preflight (CORS pre-flight check)
        if ([httpMethod isEqualToString:@"OPTIONS"]) {
            NSData *emptyBody = [NSData data];
            [self sendHTTPResponse:204 statusText:@"No Content" contentType:@"text/plain" body:emptyBody extraHeaders:nil toSocket:clientSocket keepAlive:keepAlive];
            continue;
        }
        
        // --- API Route: /ping → health check ---
        if ([requestPath isEqualToString:@"/ping"] || [requestPath isEqualToString:@"/ping/"]) {
            NSString *pingJSON = [NSString stringWithFormat:@"{\"status\":true,\"message\":\"%@\"}", self.pingMessage];
            NSData *pingData = [pingJSON dataUsingEncoding:NSUTF8StringEncoding];
            [self sendHTTPResponse:200 statusText:@"OK" contentType:@"application/json; charset=utf-8" body:pingData extraHeaders:nil toSocket:clientSocket keepAlive:keepAlive];
            continue;
        }
        
        // --- API Route: /api/files → returns all files as JSON (recursive) ---
        if ([requestPath isEqualToString:@"/api/files"] || [requestPath isEqualToString:@"/api/files/"]) {
            NSData *jsonData = [self buildFilesJSONResponse];
            [self sendHTTPResponse:200 statusText:@"OK" contentType:@"application/json; charset=utf-8" body:jsonData extraHeaders:nil toSocket:clientSocket keepAlive:keepAlive];
            continue;
        }
        
        // --- API Route: /api/dir or /api/dir/<path> → list directory contents (non-recursive) ---
        if ([requestPath isEqualToString:@"/api/dir"] || [requestPath isEqualToString:@"/api/dir/"]) {
            NSData *jsonData = [self buildDirectoryJSONForPath:@"/"];
            [self sendHTTPResponse:200 statusText:@"OK" contentType:@"application/json; charset=utf-8" body:jsonData extraHeaders:nil toSocket:clientSocket keepAlive:keepAlive];
            continue;
        }
        if ([requestPath hasPrefix:@"/api/dir/"]) {
            NSString *dirSubPath = [requestPath substringFromIndex:9]; // length of "/api/dir/"
            dirSubPath = [dirSubPath stringByRemovingPercentEncoding];
            NSData *jsonData = [self buildDirectoryJSONForPath:dirSubPath];
            [self sendHTTPResponse:200 statusText:@"OK" contentType:@"application/json; charset=utf-8" body:jsonData extraHeaders:nil toSocket:clientSocket keepAlive:keepAlive];
            continue;
        }
        
        // --- Download Route: /download/<path> → force download with Content-Disposition ---
        if ([requestPath hasPrefix:@"/download/"]) {
            NSString *dlRelativePath = [requestPath substringFromIndex:10]; // length of "/download/"
            dlRelativePath = [dlRelativePath stringByRemovingPercentEncoding];
            dlRelativePath = [dlRelativePath stringByStandardizingPath];
            if ([dlRelativePath hasPrefix:@".."] || [dlRelativePath length] == 0) {
                [self send404ToSocket:clientSocket keepAlive:keepAlive];
                continue;
            }
            NSString *downloadPath = [self.rootPath stringByAppendingPathComponent:dlRelativePath];
            NSFileManager *dlFm = [NSFileManager defaultManager];
            BOOL dlIsDir = NO;
            if (![dlFm fileExistsAtPath:downloadPath isDirectory:&dlIsDir] || dlIsDir) {
                [self send404ToSocket:clientSocket keepAlive:keepAlive];
                continue;
            }
            
            // Send file with Content-Disposition: attachment for forced download
            NSDictionary *dlAttrs = [dlFm attributesOfItemAtPath:downloadPath error:nil];
            unsigned long long dlFileSize = [dlAttrs fileSize];
            NSString *dlMimeType = [self mimeTypeForPath:downloadPath];
            NSString *dlFileName = [downloadPath lastPathComponent];
            NSString *dlEncodedName = [dlFileName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
            
            NSMutableDictionary *dlExtraHeaders = [NSMutableDictionary dictionary];
            dlExtraHeaders[@"Content-Disposition"] = [NSString stringWithFormat:@"attachment; filename=\"%@\"; filename*=UTF-8''%@", dlFileName, dlEncodedName];
            if (dlFileSize > 1024 * 1024) {
                dlExtraHeaders[@"Accept-Ranges"] = @"bytes";
            }
            
            NSData *dlHeaders = [self buildHTTPHeaders:200
                                            statusText:@"OK"
                                           contentType:dlMimeType
                                         contentLength:dlFileSize
                                          extraHeaders:dlExtraHeaders
                                             keepAlive:keepAlive];
            if (![self sendData:dlHeaders toSocket:clientSocket]) {
                break;
            }
            
            // Use efficient file descriptor streaming
            int dlFd = open([downloadPath fileSystemRepresentation], O_RDONLY);
            if (dlFd < 0) {
                continue;
            }
            
            fcntl(dlFd, F_RDAHEAD, 1);  // Sequential read hint
            
            uint8_t *dlBuffer = malloc(CHUNK_SIZE);
            if (!dlBuffer) {
                close(dlFd);
                continue;
            }
            
            BOOL dlSendOk = YES;
            while (YES) {
                @autoreleasepool {
                    ssize_t dlBytesRead = read(dlFd, dlBuffer, CHUNK_SIZE);
                    if (dlBytesRead <= 0) break;
                    
                    NSData *dlChunk = [NSData dataWithBytesNoCopy:dlBuffer length:dlBytesRead freeWhenDone:NO];
                    if (![self sendData:dlChunk toSocket:clientSocket]) {
                        dlSendOk = NO;
                        break;
                    }
                }
            }
            
            free(dlBuffer);
            close(dlFd);
            
            if (!dlSendOk) break;
            continue;
        }
        
        // Sanitize path to prevent directory traversal
        requestPath = [requestPath stringByStandardizingPath];
        if ([requestPath hasPrefix:@".."]) {
            requestPath = @"/";
        }
        
        // Build full file path
        NSString *fullPath;
        if ([requestPath isEqualToString:@"/"]) {
            fullPath = self.rootPath;
        } else {
            // Remove leading slash
            NSString *relativePath = [requestPath substringFromIndex:1];
            fullPath = [self.rootPath stringByAppendingPathComponent:relativePath];
        }
        
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        BOOL exists = [fm fileExistsAtPath:fullPath isDirectory:&isDir];
        
        if (!exists) {
            [self send404ToSocket:clientSocket keepAlive:keepAlive];
        } else if (isDir) {
            // Check for index.html
            NSString *indexPath = [fullPath stringByAppendingPathComponent:@"index.html"];
            if ([fm fileExistsAtPath:indexPath]) {
                [self sendFileAtPath:indexPath toSocket:clientSocket keepAlive:keepAlive];
            } else {
                NSData *listing = [self buildDirectoryListingResponse:fullPath requestPath:requestPath];
                [self sendHTTPResponse:200 statusText:@"OK" contentType:@"text/html; charset=utf-8" body:listing extraHeaders:nil toSocket:clientSocket keepAlive:keepAlive];
            }
        } else {
            // Stream file in chunks — handles large images/videos
            [self sendFileAtPath:fullPath toSocket:clientSocket keepAlive:keepAlive];
        }
    } // end while keep-alive loop
    
    close(clientSocket);
}

#pragma mark - Server Control

RCT_EXPORT_METHOD(start:(nonnull NSNumber *)port
                  root:(NSString *)root
                  localOnly:(BOOL)localOnly
                  pingMessage:(NSString *)pingMessage
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    
    // If already running, verify and return
    if (self.isServerRunning && self.serverSocket >= 0) {
        // Quick check — try to get socket status
        int error = 0;
        socklen_t len = sizeof(error);
        int retval = getsockopt(self.serverSocket, SOL_SOCKET, SO_ERROR, &error, &len);
        if (retval == 0 && error == 0 && self.serverURL) {
            resolve(self.serverURL);
            return;
        }
        // Socket seems dead, force cleanup
        RCTLogInfo(@"[LocalServer] Socket appears dead, cleaning up before restart");
        [self forceCleanup];
    }
    
    // Force cleanup any lingering state
    [self forceCleanup];
    
    // Normalize root path - remove file:// prefix if present
    NSString *normalizedRoot = root;
    if ([root hasPrefix:@"file://"]) {
        normalizedRoot = [[NSURL URLWithString:root] path];
    }
    
    // Verify directory exists
    BOOL isDir;
    if (![[NSFileManager defaultManager] fileExistsAtPath:normalizedRoot isDirectory:&isDir] || !isDir) {
        reject(@"INVALID_ROOT", [NSString stringWithFormat:@"Root directory does not exist: %@", normalizedRoot], nil);
        return;
    }
    
    self.rootPath = normalizedRoot;
    self.port = [port integerValue];
    self.pingMessage = (pingMessage && pingMessage.length > 0) ? pingMessage : @"pong";
    
    // Create socket
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        reject(@"SOCKET_ERROR", @"Failed to create socket", nil);
        return;
    }
    
    // Set socket options — use both SO_REUSEADDR and SO_REUSEPORT for fast rebind
    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
    
    // Bind
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(self.port);
    
    if (localOnly) {
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 127.0.0.1 only
    } else {
        addr.sin_addr.s_addr = htonl(INADDR_ANY); // All interfaces
    }
    
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int bindErr = errno;
        close(sock);
        NSString *errMsg = [NSString stringWithFormat:@"Failed to bind to port %ld (errno: %d - %s)", (long)self.port, bindErr, strerror(bindErr)];
        reject(@"BIND_ERROR", errMsg, nil);
        return;
    }
    
    // Listen with high backlog for concurrent request handling
    if (listen(sock, LISTEN_BACKLOG) < 0) {
        close(sock);
        reject(@"LISTEN_ERROR", @"Failed to listen on socket", nil);
        return;
    }
    
    // Set non-blocking
    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);
    
    self.serverSocket = sock;
    
    // Create GCD dispatch source for accepting connections
    self.serverSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, sock, 0, self.serverQueue);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.serverSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isServerRunning) return;
        
        // Accept all pending connections in a loop (dispatch source may coalesce events)
        while (YES) {
            struct sockaddr_in clientAddr;
            socklen_t clientLen = sizeof(clientAddr);
            int clientSocket = accept(strongSelf.serverSocket, (struct sockaddr *)&clientAddr, &clientLen);
            
            if (clientSocket < 0) {
                break; // No more pending connections (EAGAIN/EWOULDBLOCK)
            }
            
            // Semaphore-gated connection handling (max MAX_CONCURRENT_CONNECTIONS)
            dispatch_async(strongSelf.serverQueue, ^{
                // Wait for a slot (with 5s timeout to avoid infinite blocking)
                long waited = dispatch_semaphore_wait(strongSelf.connectionSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
                if (waited != 0) {
                    // Timeout — server is overloaded, send 503
                    const char *resp = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    send(clientSocket, resp, strlen(resp), 0);
                    close(clientSocket);
                    return;
                }
                [strongSelf handleConnection:clientSocket];
                dispatch_semaphore_signal(strongSelf.connectionSemaphore);
            });
        }
    });
    
    dispatch_source_set_cancel_handler(self.serverSource, ^{
        close(sock);
    });
    
    dispatch_resume(self.serverSource);
    
    self.isServerRunning = YES;
    
    // Build server URL
    NSString *ipAddress = localOnly ? @"127.0.0.1" : [self getWiFiIPAddress];
    self.serverURL = [NSString stringWithFormat:@"http://%@:%ld", ipAddress, (long)self.port];
    
    RCTLogInfo(@"[LocalServer] Started at %@, serving: %@", self.serverURL, self.rootPath);
    
    resolve(self.serverURL);
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [self forceCleanup];
    RCTLogInfo(@"[LocalServer] Stopped");
    resolve(@(YES));
}

RCT_EXPORT_METHOD(isRunning:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    // Verify actual socket health, not just the flag
    if (self.isServerRunning && self.serverSocket >= 0) {
        int error = 0;
        socklen_t len = sizeof(error);
        int retval = getsockopt(self.serverSocket, SOL_SOCKET, SO_ERROR, &error, &len);
        if (retval != 0 || error != 0) {
            // Socket is dead
            [self forceCleanup];
            resolve(@(NO));
            return;
        }
    }
    resolve(@(self.isServerRunning));
}

RCT_EXPORT_METHOD(getIPAddress:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    NSString *ip = [self getWiFiIPAddress];
    resolve(ip);
}

/**
 * Force cleanup all server resources — safe to call multiple times.
 * Synchronously closes socket before cancelling dispatch source
 * so the port is immediately available for re-bind.
 */
- (void)forceCleanup {
    self.isServerRunning = NO;
    
    if (self.serverSource) {
        dispatch_source_cancel(self.serverSource);
        self.serverSource = nil;
    }
    
    // Also close socket explicitly (don't rely solely on cancel handler)
    if (self.serverSocket >= 0) {
        close(self.serverSocket);
        self.serverSocket = -1;
    }
    
    self.serverURL = nil;
}

- (void)dealloc {
    [self forceCleanup];
}

@end
