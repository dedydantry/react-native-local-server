package com.reactnativelocalserver;

import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.content.Context;
import android.util.Log;

import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Collections;
import java.util.Date;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.Semaphore;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * Pure Java socket-based HTTP static file server for React Native Android.
 * Streams large files in chunks to handle images/videos of any size.
 * Feature-parity with the iOS (Objective-C) implementation.
 */
public class LocalServerModule extends ReactContextBaseJavaModule {

    private static final String TAG = "LocalServer";
    private static final int CHUNK_SIZE = 256 * 1024; // 256KB
    private static final int MAX_CONCURRENT_CONNECTIONS = 32;
    private static final int LISTEN_BACKLOG = 1024;
    private static final int KEEPALIVE_TIMEOUT = 5; // seconds idle between keep-alive requests
    private static final int KEEPALIVE_MAX_REQUESTS = 100; // max requests per persistent connection
    private static final int MAX_HEADER_SIZE = 32 * 1024;

    private volatile ServerSocket serverSocket;
    private volatile String rootPath;
    private volatile int port;
    private volatile boolean isServerRunning = false;
    private volatile String serverURL;
    private volatile String pingMessage = "pong";
    private ExecutorService executor;
    private Thread acceptThread;
    private Semaphore connectionSemaphore;

    // Serializes start()/stop() OFF the RN bridge thread so native calls never block.
    private final ExecutorService controlExecutor = Executors.newSingleThreadExecutor();

    private static final Map<String, String> MIME_TYPES = new HashMap<>();

    static {
        // Images
        MIME_TYPES.put("png", "image/png");
        MIME_TYPES.put("jpg", "image/jpeg");
        MIME_TYPES.put("jpeg", "image/jpeg");
        MIME_TYPES.put("gif", "image/gif");
        MIME_TYPES.put("webp", "image/webp");
        MIME_TYPES.put("svg", "image/svg+xml");
        MIME_TYPES.put("ico", "image/x-icon");
        MIME_TYPES.put("bmp", "image/bmp");
        MIME_TYPES.put("tiff", "image/tiff");
        MIME_TYPES.put("tif", "image/tiff");
        MIME_TYPES.put("heic", "image/heic");
        MIME_TYPES.put("heif", "image/heif");
        // Web
        MIME_TYPES.put("html", "text/html; charset=utf-8");
        MIME_TYPES.put("htm", "text/html; charset=utf-8");
        MIME_TYPES.put("css", "text/css; charset=utf-8");
        MIME_TYPES.put("js", "application/javascript; charset=utf-8");
        MIME_TYPES.put("json", "application/json; charset=utf-8");
        MIME_TYPES.put("xml", "application/xml; charset=utf-8");
        MIME_TYPES.put("txt", "text/plain; charset=utf-8");
        MIME_TYPES.put("csv", "text/csv; charset=utf-8");
        // Video
        MIME_TYPES.put("mp4", "video/mp4");
        MIME_TYPES.put("mov", "video/quicktime");
        MIME_TYPES.put("avi", "video/x-msvideo");
        MIME_TYPES.put("webm", "video/webm");
        // Audio
        MIME_TYPES.put("mp3", "audio/mpeg");
        MIME_TYPES.put("wav", "audio/wav");
        MIME_TYPES.put("ogg", "audio/ogg");
        MIME_TYPES.put("m4a", "audio/mp4");
        // Documents
        MIME_TYPES.put("pdf", "application/pdf");
        MIME_TYPES.put("zip", "application/zip");
        MIME_TYPES.put("woff", "font/woff");
        MIME_TYPES.put("woff2", "font/woff2");
        MIME_TYPES.put("ttf", "font/ttf");
        MIME_TYPES.put("otf", "font/otf");
        MIME_TYPES.put("eot", "application/vnd.ms-fontobject");
    }

    public LocalServerModule(ReactApplicationContext reactContext) {
        super(reactContext);
    }

    @Override
    public String getName() {
        return "LocalServer";
    }

    // -------------------------------------------------------------------------
    // IP Address Helper
    // -------------------------------------------------------------------------

    private String getWiFiIPAddress() {
        try {
            Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
            if (interfaces == null) return "127.0.0.1";

            for (NetworkInterface networkInterface : Collections.list(interfaces)) {
                // Check for wlan0 (WiFi on most Android devices)
                String name = networkInterface.getName();
                if (!networkInterface.isUp() || networkInterface.isLoopback()) continue;
                if (name.equals("wlan0") || name.equals("eth0") || name.startsWith("wlan")) {
                    Enumeration<InetAddress> addresses = networkInterface.getInetAddresses();
                    for (InetAddress addr : Collections.list(addresses)) {
                        if (!addr.isLoopbackAddress() && addr instanceof java.net.Inet4Address) {
                            return addr.getHostAddress();
                        }
                    }
                }
            }
        } catch (SocketException e) {
            Log.e(TAG, "Failed to get WiFi IP", e);
        }
        return "127.0.0.1";
    }

    // -------------------------------------------------------------------------
    // MIME Type Helper
    // -------------------------------------------------------------------------

    private String getMimeType(String path) {
        int dotIndex = path.lastIndexOf('.');
        if (dotIndex >= 0 && dotIndex < path.length() - 1) {
            String ext = path.substring(dotIndex + 1).toLowerCase();
            String mime = MIME_TYPES.get(ext);
            if (mime != null) return mime;
        }
        return "application/octet-stream";
    }

    private String getFileExtension(String path) {
        int dotIndex = path.lastIndexOf('.');
        if (dotIndex >= 0 && dotIndex < path.length() - 1) {
            return path.substring(dotIndex + 1).toLowerCase();
        }
        return "";
    }

    // -------------------------------------------------------------------------
    // HTTP Response Helpers
    // -------------------------------------------------------------------------

    private String buildHTTPHeaders(int statusCode, String statusText, String contentType,
                                     long contentLength, Map<String, String> extraHeaders, boolean keepAlive) {
        StringBuilder sb = new StringBuilder();
        sb.append("HTTP/1.1 ").append(statusCode).append(" ").append(statusText).append("\r\n");
        sb.append("Content-Type: ").append(contentType).append("\r\n");
        sb.append("Content-Length: ").append(contentLength).append("\r\n");
        if (keepAlive) {
            sb.append("Connection: keep-alive\r\n");
            sb.append("Keep-Alive: timeout=").append(KEEPALIVE_TIMEOUT).append(", max=").append(KEEPALIVE_MAX_REQUESTS).append("\r\n");
        } else {
            sb.append("Connection: close\r\n");
        }
        sb.append("Access-Control-Allow-Origin: *\r\n");
        sb.append("Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n");
        sb.append("Access-Control-Allow-Headers: *\r\n");
        if (extraHeaders == null || !extraHeaders.containsKey("Cache-Control")) {
            sb.append("Cache-Control: no-cache\r\n");
        }

        if (extraHeaders != null) {
            for (Map.Entry<String, String> entry : extraHeaders.entrySet()) {
                sb.append(entry.getKey()).append(": ").append(entry.getValue()).append("\r\n");
            }
        }

        sb.append("\r\n");
        return sb.toString();
    }

    private boolean sendData(OutputStream out, byte[] data) {
        try {
            out.write(data);
            out.flush();
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    private void sendHTTPResponse(OutputStream out, int statusCode, String statusText,
                                   String contentType, byte[] body, Map<String, String> extraHeaders, boolean keepAlive) {
        sendHTTPResponse(out, statusCode, statusText, contentType, body, extraHeaders, keepAlive, false);
    }

    private void sendHTTPResponse(OutputStream out, int statusCode, String statusText,
                                   String contentType, byte[] body, Map<String, String> extraHeaders, boolean keepAlive,
                                   boolean headOnly) {
        String headers = buildHTTPHeaders(statusCode, statusText, contentType, body.length, extraHeaders, keepAlive);
        sendData(out, headers.getBytes(StandardCharsets.UTF_8));
        if (!headOnly) {
            sendData(out, body);
        }
    }

    private void send404(OutputStream out, boolean keepAlive) {
        String body = "<html><body><h1>404 Not Found</h1></body></html>";
        sendHTTPResponse(out, 404, "Not Found", "text/html", body.getBytes(StandardCharsets.UTF_8), null, keepAlive);
    }

    // -------------------------------------------------------------------------
    // File Streaming
    // -------------------------------------------------------------------------

    /** RFC 1123 date for Last-Modified, always in GMT. */
    private String httpDate(long epochMillis) {
        SimpleDateFormat fmt = new SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US);
        fmt.setTimeZone(TimeZone.getTimeZone("GMT"));
        return fmt.format(new Date(epochMillis));
    }

    /**
     * Parse a single-range "Range: bytes=..." header.
     * @return {start, end} inclusive if satisfiable; {-1, -1} if unsatisfiable (→ 416);
     *         null if absent/malformed/multi-range (→ serve full 200).
     */
    private long[] parseRange(String rangeHeader, long fileSize) {
        if (rangeHeader == null) return null;
        rangeHeader = rangeHeader.trim();
        if (!rangeHeader.startsWith("bytes=")) return null;

        String spec = rangeHeader.substring(6).trim();
        if (spec.isEmpty() || spec.contains(",")) return null; // multi-range not supported → full
        int dash = spec.indexOf('-');
        if (dash < 0) return null;

        String startStr = spec.substring(0, dash).trim();
        String endStr = spec.substring(dash + 1).trim();
        try {
            long start, end;
            if (startStr.isEmpty()) {
                // suffix range: last N bytes
                if (endStr.isEmpty()) return null;
                long n = Long.parseLong(endStr);
                if (n <= 0) return new long[]{-1, -1};
                start = Math.max(0, fileSize - n);
                end = fileSize - 1;
            } else {
                start = Long.parseLong(startStr);
                end = endStr.isEmpty() ? fileSize - 1 : Long.parseLong(endStr);
            }
            if (start > end || start >= fileSize) return new long[]{-1, -1};
            if (end >= fileSize) end = fileSize - 1;
            return new long[]{start, end};
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /**
     * Serve a file with HTTP Range, conditional-GET (ETag/If-None-Match), keep-alive and HEAD support.
     * Handles both inline serving and forced-download (attachment) in one path so iOS/Android stay in parity.
     */
    private void serveFile(OutputStream out, File file, boolean keepAlive, boolean headOnly,
                           boolean attachment, Map<String, String> reqHeaders) {
        long fileSize = file.length();
        if (fileSize == 0) {
            send404(out, keepAlive);
            return;
        }

        String mimeType = getMimeType(file.getName());
        long lastModified = file.lastModified();
        String etag = "\"" + fileSize + "-" + lastModified + "\"";

        // Conditional GET — let clients/browsers revalidate cheaply (304, no body).
        String ifNoneMatch = reqHeaders.get("if-none-match");
        if (ifNoneMatch != null && ifNoneMatch.equals(etag)) {
            Map<String, String> h = new HashMap<>();
            h.put("ETag", etag);
            h.put("Cache-Control", "no-cache");
            sendHTTPResponse(out, 304, "Not Modified", mimeType, new byte[0], h, keepAlive, true);
            return;
        }

        // Range — only honor when If-Range is absent or matches the current ETag,
        // so a resumed download can never splice bytes from a changed file.
        String rangeHeader = reqHeaders.get("range");
        String ifRange = reqHeaders.get("if-range");
        boolean rangeAllowed = rangeHeader != null && (ifRange == null || ifRange.equals(etag));

        long start = 0;
        long end = fileSize - 1;
        boolean partial = false;

        if (rangeAllowed) {
            long[] parsed = parseRange(rangeHeader, fileSize);
            if (parsed != null && parsed[0] == -1) {
                Map<String, String> h = new HashMap<>();
                h.put("Content-Range", "bytes */" + fileSize);
                h.put("Accept-Ranges", "bytes");
                sendHTTPResponse(out, 416, "Range Not Satisfiable", "text/plain",
                        new byte[0], h, keepAlive, headOnly);
                return;
            }
            if (parsed != null) {
                start = parsed[0];
                end = parsed[1];
                partial = true;
            }
        }

        long contentLength = end - start + 1;

        Map<String, String> extra = new HashMap<>();
        extra.put("Accept-Ranges", "bytes");
        extra.put("ETag", etag);
        extra.put("Last-Modified", httpDate(lastModified));
        extra.put("Cache-Control", "no-cache");
        if (attachment) {
            String fileName = file.getName();
            String encodedName;
            try {
                encodedName = URLEncoder.encode(fileName, "UTF-8").replace("+", "%20");
            } catch (Exception e) {
                encodedName = fileName;
            }
            extra.put("Content-Disposition",
                    "attachment; filename=\"" + fileName + "\"; filename*=UTF-8''" + encodedName);
        }
        if (partial) {
            extra.put("Content-Range", "bytes " + start + "-" + end + "/" + fileSize);
        }

        int statusCode = partial ? 206 : 200;
        String statusText = partial ? "Partial Content" : "OK";

        String headers = buildHTTPHeaders(statusCode, statusText, mimeType, contentLength, extra, keepAlive);
        if (!sendData(out, headers.getBytes(StandardCharsets.UTF_8))) return;
        if (headOnly) return;

        // Stream exactly [start, end] in 256KB chunks.
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            raf.seek(start);
            byte[] buffer = new byte[CHUNK_SIZE];
            long remaining = contentLength;
            while (remaining > 0) {
                int toRead = (int) Math.min(buffer.length, remaining);
                int read = raf.read(buffer, 0, toRead);
                if (read == -1) break;
                try {
                    out.write(buffer, 0, read);
                } catch (IOException e) {
                    break; // Client disconnected
                }
                remaining -= read;
            }
            out.flush();
        } catch (IOException e) {
            Log.e(TAG, "Error streaming file: " + file.getAbsolutePath(), e);
        }
    }

    // -------------------------------------------------------------------------
    // Directory Listing (HTML)
    // -------------------------------------------------------------------------

    private byte[] buildDirectoryListingResponse(File dir, String requestPath) {
        StringBuilder html = new StringBuilder();
        html.append("<html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'>");
        html.append("<style>body{font-family:-apple-system,sans-serif;padding:20px;background:#1a1a2e;color:#fff}");
        html.append("a{color:#818cf8;text-decoration:none;display:block;padding:8px 0}a:hover{text-decoration:underline}</style>");
        html.append("</head><body><h2>Index of ").append(requestPath).append("</h2>");

        if (!"/".equals(requestPath)) {
            html.append("<a href='../'>..</a>");
        }

        File[] contents = dir.listFiles();
        if (contents != null) {
            for (File item : contents) {
                if (item.isDirectory()) {
                    html.append("<a href='").append(item.getName()).append("/'>&#128193; ")
                            .append(item.getName()).append("/</a>");
                } else {
                    long fileSize = item.length();
                    String sizeStr;
                    if (fileSize < 1024) {
                        sizeStr = fileSize + " B";
                    } else if (fileSize < 1024 * 1024) {
                        sizeStr = String.format("%.1f KB", fileSize / 1024.0);
                    } else {
                        sizeStr = String.format("%.1f MB", fileSize / (1024.0 * 1024.0));
                    }
                    html.append("<a href='").append(item.getName()).append("'>&#128196; ")
                            .append(item.getName())
                            .append(" <small style='color:#888'>(").append(sizeStr).append(")</small></a>");
                }
            }
        }

        html.append("</body></html>");
        return html.toString().getBytes(StandardCharsets.UTF_8);
    }

    // -------------------------------------------------------------------------
    // API: /api/files — recursive file listing as JSON
    // -------------------------------------------------------------------------

    private void collectFiles(File dir, String basePath, JSONArray results) {
        File[] contents = dir.listFiles();
        if (contents == null) return;

        for (File item : contents) {
            if (item.isDirectory()) {
                collectFiles(item, basePath, results);
            } else {
                try {
                    String fullPath = item.getAbsolutePath();
                    String relativePath = "";
                    if (fullPath.length() > basePath.length()) {
                        relativePath = fullPath.substring(basePath.length());
                        if (relativePath.startsWith("/")) {
                            relativePath = relativePath.substring(1);
                        }
                    }

                    String encodedPath = URLEncoder.encode(relativePath, "UTF-8")
                            .replace("+", "%20").replace("%2F", "/");
                    String downloadURL = serverURL + "/download/" + encodedPath;
                    String mimeType = getMimeType(fullPath);
                    String ext = getFileExtension(fullPath);

                    JSONObject fileInfo = new JSONObject();
                    fileInfo.put("name", item.getName());
                    fileInfo.put("path", relativePath);
                    fileInfo.put("url", downloadURL);
                    fileInfo.put("size", item.length());
                    fileInfo.put("mime", mimeType);
                    fileInfo.put("ext", ext);
                    fileInfo.put("modified", item.lastModified());

                    results.put(fileInfo);
                } catch (Exception e) {
                    Log.e(TAG, "Error collecting file info", e);
                }
            }
        }
    }

    private byte[] buildFilesJSONResponse() {
        try {
            JSONArray files = new JSONArray();
            File root = new File(rootPath);
            collectFiles(root, rootPath, files);

            JSONObject response = new JSONObject();
            response.put("success", true);
            response.put("root", rootPath);
            response.put("server", serverURL);
            response.put("total", files.length());
            response.put("files", files);

            return response.toString(2).getBytes(StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "{\"success\":false,\"error\":\"Failed to serialize JSON\"}".getBytes(StandardCharsets.UTF_8);
        }
    }

    // -------------------------------------------------------------------------
    // API: /api/dir — non-recursive directory listing as JSON
    // -------------------------------------------------------------------------

    private byte[] buildDirectoryJSONForPath(String relativeDirPath) {
        try {
            File targetDir;
            if (relativeDirPath == null || relativeDirPath.isEmpty() || "/".equals(relativeDirPath)) {
                targetDir = new File(rootPath);
                relativeDirPath = "/";
            } else {
                // Sanitize — prevent traversal
                if (relativeDirPath.contains("..")) {
                    return "{\"success\":false,\"error\":\"Invalid path\"}".getBytes(StandardCharsets.UTF_8);
                }
                // Remove leading slash
                String cleaned = relativeDirPath;
                if (cleaned.startsWith("/")) {
                    cleaned = cleaned.substring(1);
                }
                targetDir = new File(rootPath, cleaned);
            }

            if (!targetDir.exists() || !targetDir.isDirectory()) {
                JSONObject err = new JSONObject();
                err.put("success", false);
                err.put("error", "Directory not found");
                err.put("path", relativeDirPath);
                return err.toString().getBytes(StandardCharsets.UTF_8);
            }

            File[] contents = targetDir.listFiles();
            JSONArray items = new JSONArray();

            if (contents != null) {
                for (File item : contents) {
                    String fullItemPath = item.getAbsolutePath();

                    // Build relative path from root
                    String itemRelativePath = "";
                    if (fullItemPath.length() > rootPath.length()) {
                        itemRelativePath = fullItemPath.substring(rootPath.length());
                        if (itemRelativePath.startsWith("/")) {
                            itemRelativePath = itemRelativePath.substring(1);
                        }
                    }

                    JSONObject itemInfo = new JSONObject();
                    itemInfo.put("name", item.getName());
                    itemInfo.put("path", itemRelativePath);

                    if (item.isDirectory()) {
                        itemInfo.put("type", "directory");
                        File[] children = item.listFiles();
                        itemInfo.put("children", children != null ? children.length : 0);
                    } else {
                        itemInfo.put("type", "file");
                        itemInfo.put("size", item.length());
                        itemInfo.put("mime", getMimeType(fullItemPath));
                        itemInfo.put("ext", getFileExtension(fullItemPath));

                        String encodedPath = URLEncoder.encode(itemRelativePath, "UTF-8")
                                .replace("+", "%20").replace("%2F", "/");
                        itemInfo.put("url", serverURL + "/" + encodedPath);
                        itemInfo.put("download", serverURL + "/download/" + encodedPath);
                    }

                    itemInfo.put("modified", item.lastModified());
                    items.put(itemInfo);
                }
            }

            JSONObject response = new JSONObject();
            response.put("success", true);
            response.put("path", relativeDirPath);
            response.put("server", serverURL);
            response.put("total", items.length());
            response.put("items", items);

            return response.toString(2).getBytes(StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "{\"success\":false,\"error\":\"Failed to serialize JSON\"}".getBytes(StandardCharsets.UTF_8);
        }
    }

    // -------------------------------------------------------------------------
    // Request Parser
    // -------------------------------------------------------------------------

    private String parseRequestPath(String requestLine) {
        if (requestLine == null || requestLine.isEmpty()) return "/";

        // Parse first line: "GET /path HTTP/1.1"
        String[] parts = requestLine.split(" ");
        if (parts.length < 2) return "/";

        String path = parts[1];

        // URL decode
        try {
            path = URLDecoder.decode(path, "UTF-8");
        } catch (Exception e) {
            // keep as-is
        }

        // Remove query string
        int queryIndex = path.indexOf('?');
        if (queryIndex >= 0) {
            path = path.substring(0, queryIndex);
        }

        return path.isEmpty() ? "/" : path;
    }

    /**
     * Read exactly up to (and including) the blank line that ends the HTTP headers.
     * Reads byte-by-byte from the (buffered) stream so any following request's bytes
     * stay in the buffer — required for correct keep-alive handling.
     */
    private String readHTTPRequest(InputStream in) throws IOException {
        ByteArrayOutputStream requestData = new ByteArrayOutputStream();
        int state = 0; // tracks the \r\n\r\n terminator

        while (requestData.size() < MAX_HEADER_SIZE) {
            int b = in.read();
            if (b == -1) {
                return requestData.size() > 0 ? requestData.toString("UTF-8") : null;
            }
            requestData.write(b);

            switch (state) {
                case 0: state = (b == '\r') ? 1 : 0; break;
                case 1: state = (b == '\n') ? 2 : (b == '\r' ? 1 : 0); break;
                case 2: state = (b == '\r') ? 3 : 0; break;
                case 3:
                    if (b == '\n') return requestData.toString("UTF-8");
                    state = 0;
                    break;
            }
        }

        Log.w(TAG, "Request headers exceeded " + MAX_HEADER_SIZE + " bytes");
        return null;
    }

    /** Parse request header lines (after the request line) into a lowercase-keyed map. */
    private Map<String, String> parseHeaders(String[] lines) {
        Map<String, String> headers = new HashMap<>();
        for (int i = 1; i < lines.length; i++) {
            String line = lines[i];
            if (line.isEmpty()) break; // end of headers
            int colon = line.indexOf(':');
            if (colon > 0) {
                String key = line.substring(0, colon).trim().toLowerCase();
                String value = line.substring(colon + 1).trim();
                headers.put(key, value);
            }
        }
        return headers;
    }

    // -------------------------------------------------------------------------
    // Connection Handler
    // -------------------------------------------------------------------------

    private void handleConnection(Socket clientSocket) {
        boolean acquired = false;
        try {
            // Semaphore-gated: limit concurrent connections
            acquired = connectionSemaphore.tryAcquire(5, TimeUnit.SECONDS);
            if (!acquired) {
                // Server overloaded — send 503 and close
                try {
                    OutputStream out = clientSocket.getOutputStream();
                    String resp = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    out.write(resp.getBytes(StandardCharsets.UTF_8));
                    out.flush();
                } catch (IOException ignored) {}
                return;
            }

            clientSocket.setTcpNoDelay(true);  // Disable Nagle for lower latency

            // Buffered so readHTTPRequest can read byte-by-byte without per-byte syscalls,
            // and so leftover bytes of a pipelined request survive between keep-alive iterations.
            InputStream in = new BufferedInputStream(clientSocket.getInputStream(), 8192);
            OutputStream out = clientSocket.getOutputStream();

            int requestCount = 0;
            boolean keepAlive = true;

            while (keepAlive && requestCount < KEEPALIVE_MAX_REQUESTS && isServerRunning) {

                // First request gets a generous timeout; subsequent ones use the keep-alive idle window.
                clientSocket.setSoTimeout(requestCount == 0 ? 30000 : KEEPALIVE_TIMEOUT * 1000);

                String requestStr = readHTTPRequest(in);
                if (requestStr == null || requestStr.isEmpty()) break; // Client closed or idle timeout

                requestCount++;

                String[] lines = requestStr.split("\r\n");
                String requestLine = lines.length > 0 ? lines[0] : "";
                Map<String, String> reqHeaders = parseHeaders(lines);

                String requestPath = parseRequestPath(requestLine);
                Log.i(TAG, "Request #" + requestCount + ": " + requestPath);

                // Extract HTTP method
                String httpMethod = "GET";
                String[] requestParts = requestLine.split(" ");
                if (requestParts.length > 0) {
                    httpMethod = requestParts[0].toUpperCase();
                }
                boolean headOnly = "HEAD".equals(httpMethod);

                // Keep the connection alive unless the client asked to close or we hit the per-socket cap.
                String connHeader = reqHeaders.get("connection");
                boolean clientWantsClose = connHeader != null && connHeader.toLowerCase().contains("close");
                keepAlive = !clientWantsClose && requestCount < KEEPALIVE_MAX_REQUESTS && isServerRunning;

                // Handle OPTIONS preflight (CORS pre-flight check)
                if ("OPTIONS".equals(httpMethod)) {
                    sendHTTPResponse(out, 204, "No Content", "text/plain", new byte[0], null, keepAlive, headOnly);
                    continue;
                }

                // --- API Route: /ping → health check ---
                if ("/ping".equals(requestPath) || "/ping/".equals(requestPath)) {
                    byte[] pingBody = ("{\"status\":true,\"message\":\"" + pingMessage + "\"}").getBytes(StandardCharsets.UTF_8);
                    sendHTTPResponse(out, 200, "OK", "application/json; charset=utf-8", pingBody, null, keepAlive, headOnly);
                    continue;
                }

                // --- API Route: /api/files → returns all files as JSON (recursive) ---
                if ("/api/files".equals(requestPath) || "/api/files/".equals(requestPath)) {
                    byte[] jsonData = buildFilesJSONResponse();
                    sendHTTPResponse(out, 200, "OK", "application/json; charset=utf-8", jsonData, null, keepAlive, headOnly);
                    continue;
                }

                // --- API Route: /api/dir or /api/dir/<path> → list directory contents (non-recursive) ---
                if ("/api/dir".equals(requestPath) || "/api/dir/".equals(requestPath)) {
                    byte[] jsonData = buildDirectoryJSONForPath("/");
                    sendHTTPResponse(out, 200, "OK", "application/json; charset=utf-8", jsonData, null, keepAlive, headOnly);
                    continue;
                }
                if (requestPath.startsWith("/api/dir/")) {
                    String dirSubPath = requestPath.substring(9); // length of "/api/dir/"
                    try {
                        dirSubPath = URLDecoder.decode(dirSubPath, "UTF-8");
                    } catch (Exception ignored) {}
                    byte[] jsonData = buildDirectoryJSONForPath(dirSubPath);
                    sendHTTPResponse(out, 200, "OK", "application/json; charset=utf-8", jsonData, null, keepAlive, headOnly);
                    continue;
                }

                // --- Download Route: /download/<path> → force download with Content-Disposition ---
                if (requestPath.startsWith("/download/")) {
                    String dlRelativePath = requestPath.substring(10); // length of "/download/"
                    try {
                        dlRelativePath = URLDecoder.decode(dlRelativePath, "UTF-8");
                    } catch (Exception ignored) {}

                    // Sanitize
                    if (dlRelativePath.contains("..") || dlRelativePath.isEmpty()) {
                        send404(out, keepAlive);
                        continue;
                    }

                    File downloadFile = new File(rootPath, dlRelativePath);
                    if (!downloadFile.exists() || downloadFile.isDirectory()) {
                        send404(out, keepAlive);
                        continue;
                    }

                    serveFile(out, downloadFile, keepAlive, headOnly, true, reqHeaders);
                    continue;
                }

                // Sanitize path to prevent directory traversal
                if (requestPath.contains("..")) {
                    requestPath = "/";
                }

                // Build full file path
                File fullPath;
                if ("/".equals(requestPath)) {
                    fullPath = new File(rootPath);
                } else {
                    String relativePath = requestPath.startsWith("/") ? requestPath.substring(1) : requestPath;
                    fullPath = new File(rootPath, relativePath);
                }

                if (!fullPath.exists()) {
                    send404(out, keepAlive);
                } else if (fullPath.isDirectory()) {
                    // Check for index.html
                    File indexFile = new File(fullPath, "index.html");
                    if (indexFile.exists()) {
                        serveFile(out, indexFile, keepAlive, headOnly, false, reqHeaders);
                    } else {
                        byte[] listing = buildDirectoryListingResponse(fullPath, requestPath);
                        sendHTTPResponse(out, 200, "OK", "text/html; charset=utf-8", listing, null, keepAlive, headOnly);
                    }
                } else {
                    // Stream file in chunks (with Range/resume support) — handles large images/videos
                    serveFile(out, fullPath, keepAlive, headOnly, false, reqHeaders);
                }
            } // end while keep-alive loop

        } catch (IOException | InterruptedException e) {
            Log.e(TAG, "Error handling connection", e);
        } finally {
            if (acquired) {
                connectionSemaphore.release();
            }
            try {
                clientSocket.close();
            } catch (IOException ignored) {}
        }
    }

    // -------------------------------------------------------------------------
    // Server Control (React Native Methods)
    // -------------------------------------------------------------------------

    @ReactMethod
    public void start(double portNumber, String root, boolean localOnly, String pingMessage, Promise promise) {
        // Run off the RN bridge thread — startInternal blocks (cleanup join/awaitTermination, bind retry).
        controlExecutor.execute(() -> startInternal(portNumber, root, localOnly, pingMessage, promise));
    }

    private void startInternal(double portNumber, String root, boolean localOnly, String pingMessage, Promise promise) {
        // If already running, verify and return
        if (isServerRunning && serverSocket != null && !serverSocket.isClosed()) {
            try {
                // Quick health check — try to verify socket is alive
                if (serverSocket.isBound() && serverURL != null) {
                    promise.resolve(serverURL);
                    return;
                }
            } catch (Exception e) {
                Log.w(TAG, "Server appears dead, cleaning up before restart: " + e.getMessage());
            }
            forceCleanup();
        }

        // Force cleanup any lingering state (previous server that wasn't stopped cleanly)
        forceCleanup();

        // Normalize root path — remove file:// prefix if present
        String normalizedRoot = root;
        if (root.startsWith("file://")) {
            normalizedRoot = root.substring(7);
        }

        // Verify directory exists
        File rootDir = new File(normalizedRoot);
        if (!rootDir.exists() || !rootDir.isDirectory()) {
            promise.reject("INVALID_ROOT", "Root directory does not exist: " + normalizedRoot);
            return;
        }

        this.rootPath = normalizedRoot;
        // Ensure rootPath ends without trailing slash for consistent relative path building
        if (this.rootPath.endsWith("/")) {
            this.rootPath = this.rootPath.substring(0, this.rootPath.length() - 1);
        }
        this.port = (int) portNumber;
        this.pingMessage = (pingMessage != null && !pingMessage.isEmpty()) ? pingMessage : "pong";

        // Try to release lingering TIME_WAIT on the port
        forceReleasePort(this.port);

        // Bind with retry — port may take a moment to be freed after forceCleanup
        IOException lastBindError = null;
        for (int attempt = 1; attempt <= 3; attempt++) {
            try {
                serverSocket = new ServerSocket();
                serverSocket.setReuseAddress(true);

                if (localOnly) {
                    serverSocket.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), this.port), LISTEN_BACKLOG);
                } else {
                    serverSocket.bind(new InetSocketAddress(this.port), LISTEN_BACKLOG);
                }
                lastBindError = null;
                break; // bind succeeded
            } catch (IOException e) {
                lastBindError = e;
                Log.w(TAG, "Bind attempt " + attempt + " failed: " + e.getMessage());
                // Close the failed socket before retry
                try { if (serverSocket != null) serverSocket.close(); } catch (IOException ignored) {}
                serverSocket = null;
                if (attempt < 3) {
                    try { Thread.sleep(500 * attempt); } catch (InterruptedException ignored) {}
                    forceReleasePort(this.port);
                }
            }
        }

        if (lastBindError != null || serverSocket == null) {
            forceCleanup();
            promise.reject("START_ERROR", "Failed to bind port " + this.port + " after 3 attempts: "
                    + (lastBindError != null ? lastBindError.getMessage() : "unknown error"), lastBindError);
            return;
        }

        try {
            // Bounded thread pool: keep mobile file serving stable under gallery bursts.
            // core == max so concurrency actually reaches MAX_CONCURRENT_CONNECTIONS; with a
            // LinkedBlockingQueue a smaller core would never grow past core until the queue filled.
            // allowCoreThreadTimeOut lets idle threads die so we don't hold MAX threads forever.
            connectionSemaphore = new Semaphore(MAX_CONCURRENT_CONNECTIONS);
            ThreadPoolExecutor pool = new ThreadPoolExecutor(
                MAX_CONCURRENT_CONNECTIONS,    // core pool size
                MAX_CONCURRENT_CONNECTIONS,    // max pool size
                60L, TimeUnit.SECONDS,         // idle thread keepalive
                new LinkedBlockingQueue<>(LISTEN_BACKLOG)  // work queue
            );
            pool.allowCoreThreadTimeOut(true);
            executor = pool;

            // Accept thread
            acceptThread = new Thread(() -> {
                while (!Thread.currentThread().isInterrupted() && serverSocket != null && !serverSocket.isClosed()) {
                    try {
                        Socket client = serverSocket.accept();
                        executor.execute(() -> handleConnection(client));
                    } catch (IOException e) {
                        if (!Thread.currentThread().isInterrupted()) {
                            Log.e(TAG, "Accept error", e);
                        }
                        break;
                    }
                }
            });
            acceptThread.setDaemon(true);
            acceptThread.start();

            isServerRunning = true;

            // Build server URL
            String ipAddress = localOnly ? "127.0.0.1" : getWiFiIPAddress();
            serverURL = "http://" + ipAddress + ":" + this.port;

            Log.i(TAG, "Started at " + serverURL + ", serving: " + this.rootPath);
            promise.resolve(serverURL);

        } catch (Exception e) {
            forceCleanup();
            promise.reject("START_ERROR", "Failed to start server: " + e.getMessage(), e);
        }
    }

    @ReactMethod
    public void stop(Promise promise) {
        // forceCleanup() joins the accept thread and awaits connection drain — keep it off the bridge.
        controlExecutor.execute(() -> {
            forceCleanup();
            Log.i(TAG, "Stopped");
            promise.resolve(true);
        });
    }

    @ReactMethod
    public void isRunning(Promise promise) {
        // Verify actual socket health, not just the flag
        if (isServerRunning) {
            if (serverSocket == null || serverSocket.isClosed()) {
                forceCleanup();
                promise.resolve(false);
                return;
            }
        }
        promise.resolve(isServerRunning);
    }

    @ReactMethod
    public void getIPAddress(Promise promise) {
        promise.resolve(getWiFiIPAddress());
    }

    /**
     * Force cleanup all server resources — safe to call multiple times.
     * Closes socket FIRST to unblock the accept thread, then waits for
     * active connections to drain so the port is fully released.
     */
    private void forceCleanup() {
        isServerRunning = false;
        serverURL = null;

        // 1. Close server socket FIRST — unblocks accept() immediately
        if (serverSocket != null) {
            try {
                if (!serverSocket.isClosed()) {
                    serverSocket.close();
                }
            } catch (IOException e) {
                Log.w(TAG, "Error closing server socket: " + e.getMessage());
            }
            serverSocket = null;
        }

        // 2. Interrupt accept thread and wait for it to exit
        if (acceptThread != null) {
            acceptThread.interrupt();
            try {
                acceptThread.join(3000); // wait up to 3s
            } catch (InterruptedException ignored) {}
            acceptThread = null;
        }

        // 3. Shutdown executor and WAIT for active connections to close
        //    This ensures all client sockets are closed and the port is freed.
        if (executor != null) {
            executor.shutdownNow();
            try {
                if (!executor.awaitTermination(5, TimeUnit.SECONDS)) {
                    Log.w(TAG, "Executor did not terminate within 5s");
                }
            } catch (InterruptedException ignored) {}
            executor = null;
        }
    }

    /**
     * Try to kill any lingering socket holding the given port.
     * Creates a momentary connection to trigger the OS to release TIME_WAIT state,
     * then immediately closes it. Harmless if nothing is listening.
     */
    private void forceReleasePort(int targetPort) {
        try {
            Socket probe = new Socket();
            probe.setSoLinger(true, 0); // RST on close — forces OS to release immediately
            probe.connect(new InetSocketAddress("127.0.0.1", targetPort), 200);
            probe.close();
        } catch (IOException ignored) {
            // Expected — nothing listening, or connect refused. Port is likely free.
        }
    }
}
