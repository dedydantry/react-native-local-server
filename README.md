# react-native-local-server

A lightweight local HTTP static file server for React Native, serving files from any local
directory over HTTP with chunked streaming, CORS, HTTP Range (resumable downloads), and
built-in JSON APIs for file/directory listing.

> **Implementation note:** iOS is built on [GCDWebServer](https://github.com/swisspol/GCDWebServer)
> (a small, battle-tested Objective-C HTTP server). Android is a self-contained pure-Java
> `ServerSocket` implementation. They are kept at feature parity (Range, keep-alive,
> conditional GET, HEAD), but are two distinct implementations — test platform behavior separately.

## Features

- **Large file streaming** — 256KB chunked transfer, handles images/videos of any size
- **HTTP Range / resumable downloads** — `Accept-Ranges: bytes`, `206 Partial Content`, `416` — interrupted transfers resume instead of restarting (both platforms)
- **Conditional GET** — `ETag` + `Last-Modified`; `If-None-Match` → `304 Not Modified` (cheap revalidation, no stale photos)
- **Keep-alive** — persistent connections reuse the TCP socket across requests (fast galleries)
- **Cross-platform** — iOS (GCDWebServer) and Android (pure Java sockets)
- **Static file serving** — serves any file type with proper MIME types
- **JSON API endpoints** — `/api/files` (recursive) and `/api/dir` (non-recursive)
- **Force download endpoint** — `/download/<path>` with `Content-Disposition: attachment`
- **Directory listing** — auto-generated HTML index for directories
- **CORS enabled** — all responses include CORS headers
- **WiFi IP detection** — automatically detects device WiFi IP address
- **Local-only mode** — optionally bind to `127.0.0.1` only
- **Path traversal protection** — sanitizes all request paths

## Installation

```bash
npm install react-native-local-server
```

### iOS

```bash
cd ios && pod install
```

### Android

No additional steps required. Permissions (`INTERNET`, `ACCESS_WIFI_STATE`) are declared in the library manifest and merged automatically.

> **Note:** This library requires React Native's new architecture or the classic bridge. It does **not** work with Expo Go — use a [development build](https://docs.expo.dev/develop/development-builds/introduction/).

## Usage

### Basic Server

```javascript
import StaticServer from 'react-native-local-server';

// Create server on port 8080, serving files from a local directory
const server = new StaticServer(8080, '/path/to/files');

// Start the server
const url = await server.start();
console.log('Server running at:', url);
// => "http://192.168.1.10:8080"

// Stop the server
await server.stop();
```

### Local-Only Server (127.0.0.1)

```javascript
const server = new StaticServer(8080, '/path/to/files', { localOnly: true });
const url = await server.start();
// => "http://127.0.0.1:8080"
```

### List All Files (Recursive)

```javascript
const server = new StaticServer(8080, '/path/to/files');
await server.start();

const result = await server.getFiles();
console.log(result);
// {
//   success: true,
//   root: "/path/to/files",
//   server: "http://192.168.1.10:8080",
//   total: 42,
//   files: [
//     {
//       name: "photo.png",
//       path: "events/wedding/photo.png",
//       url: "http://192.168.1.10:8080/download/events/wedding/photo.png",
//       size: 1234567,
//       mime: "image/png",
//       ext: "png",
//       modified: 1708300000000
//     },
//     ...
//   ]
// }
```

### List Directory Contents (Non-Recursive)

```javascript
// List root directory
const root = await server.getDir();

// List a subdirectory
const eventDir = await server.getDir('events/wedding');
console.log(eventDir);
// {
//   success: true,
//   path: "events/wedding",
//   server: "http://192.168.1.10:8080",
//   total: 3,
//   items: [
//     { name: "photos", path: "events/wedding/photos", type: "directory", children: 24, modified: 1708300000000 },
//     { name: "cover.png", path: "events/wedding/cover.png", type: "file", size: 456789, mime: "image/png", ext: "png", url: "http://...", download: "http://.../download/...", modified: 1708200000000 },
//     ...
//   ]
// }
```

### URL Helpers

```javascript
// Get direct file URL (inline viewing)
server.getFileURL('events/wedding/photo.png');
// => "http://192.168.1.10:8080/events/wedding/photo.png"

// Get download URL (forces download with Content-Disposition header)
server.getDownloadURL('events/wedding/photo.png');
// => "http://192.168.1.10:8080/download/events/wedding/photo.png"

// Get API URLs
server.getFilesAPIUrl();
// => "http://192.168.1.10:8080/api/files"

server.getDirAPIUrl('events/wedding');
// => "http://192.168.1.10:8080/api/dir/events/wedding"
```

### Get WiFi IP Address

```javascript
const ip = await StaticServer.getIPAddress();
console.log(ip); // "192.168.1.10"
```

### React Native Example with Cleanup

```javascript
import React, { useEffect, useRef } from 'react';
import StaticServer from 'react-native-local-server';
import * as FileSystem from 'expo-file-system';

function MyScreen() {
  const serverRef = useRef(null);

  useEffect(() => {
    const startServer = async () => {
      const rootDir = FileSystem.documentDirectory + 'my-files/';
      const server = new StaticServer(3000, rootDir);
      const url = await server.start();
      serverRef.current = server;
      console.log('Server at:', url);
    };

    startServer();

    return () => {
      // Cleanup on unmount
      if (serverRef.current) {
        serverRef.current.stop();
        serverRef.current = null;
      }
    };
  }, []);

  return <View />;
}
```

## API Reference

### `new StaticServer(port, root, options?)`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `port` | `number` | `8080` | Port to listen on |
| `root` | `string` | `''` | Absolute path to the directory to serve |
| `options.localOnly` | `boolean` | `false` | Bind to `127.0.0.1` only |

### Instance Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `start()` | `Promise<string>` | Start server, returns URL |
| `stop()` | `Promise<void>` | Stop server |
| `isRunning()` | `Promise<boolean>` | Check if server is running |
| `getURL()` | `string \| null` | Get server URL (sync) |
| `getFiles()` | `Promise<Object>` | List all files recursively (JSON) |
| `getDir(path?)` | `Promise<Object>` | List directory contents non-recursively (JSON) |
| `getFileURL(path)` | `string \| null` | Get direct URL for a file |
| `getDownloadURL(path)` | `string \| null` | Get forced-download URL for a file |
| `getFilesAPIUrl()` | `string \| null` | Get `/api/files` endpoint URL |
| `getDirAPIUrl(path?)` | `string \| null` | Get `/api/dir` endpoint URL |

### Static Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `StaticServer.getIPAddress()` | `Promise<string>` | Get device WiFi IP address |

## HTTP Endpoints

When the server is running, these endpoints are available:

| Endpoint | Description |
|----------|-------------|
| `GET /` | Serve root directory (index.html or directory listing) |
| `GET /<path>` | Serve file or directory at path |
| `GET /api/files` | JSON array of all files (recursive) |
| `GET /api/dir` | JSON listing of root directory contents |
| `GET /api/dir/<path>` | JSON listing of subdirectory contents |
| `GET /download/<path>` | Force download file with `Content-Disposition: attachment` |
| `POST /global-post` | Capture request body and forward it to JS (see below). Always replies `200 {success, requestId}` immediately (fire-and-forget). |

## Receiving POST data in JS (`/global-post`)

`POST /global-post` lets another device/process push data into the app. The native server
captures the body, **immediately replies `200 OK`**, and forwards the request to JS via an event.
The body is handled by `Content-Type`:

- **JSON / text** (`application/json`, `text/*`, …) → delivered inline as a `body` string.
- **Everything else** (images, binary, or oversized text >8MB) → written to a temp file; the
  absolute `filePath` is delivered instead (no large bytes cross the bridge).

```javascript
import StaticServer from 'react-native-local-server';
import * as FileSystem from 'expo-file-system';

const sub = StaticServer.addRequestListener(async (req) => {
  // req: { requestId, path, method, contentType, query, size, headers, bodyType, body?, filePath? }
  if (req.bodyType === 'json') {
    const data = JSON.parse(req.body);
    console.log('Got JSON:', data);
  } else if (req.bodyType === 'file') {
    // Move it somewhere permanent — the library does NOT clean up the temp file.
    const dest = FileSystem.documentDirectory + 'incoming.jpg';
    await FileSystem.moveAsync({ from: 'file://' + req.filePath, to: dest });
    console.log('Got file:', dest, req.size, 'bytes');
  }
});

// later: sub.remove();
```

Posting from another device:

```bash
# JSON → arrives as req.body (string)
curl -X POST http://192.168.1.10:8080/global-post \
  -H 'Content-Type: application/json' -d '{"hello":"world"}'

# Image → arrives as req.filePath
curl -X POST http://192.168.1.10:8080/global-post \
  -H 'Content-Type: image/jpeg' --data-binary @photo.jpg
```

> Metadata can travel in custom headers (e.g. `X-My-Meta`) — all request headers are forwarded
> in `req.headers` (lowercase keys). Use `Content-Length`; chunked `Transfer-Encoding` returns `411`.

## Supported MIME Types

Images: `png`, `jpg`, `jpeg`, `gif`, `webp`, `svg`, `ico`, `bmp`, `tiff`, `heic`, `heif`
Web: `html`, `css`, `js`, `json`, `xml`, `txt`, `csv`
Video: `mp4`, `mov`, `avi`, `webm`
Audio: `mp3`, `wav`, `ogg`, `m4a`
Documents: `pdf`, `zip`
Fonts: `woff`, `woff2`, `ttf`, `otf`, `eot`

Unrecognized extensions default to `application/octet-stream`.

## Platform Details

| | iOS | Android |
|---|---|---|
| HTTP engine | GCDWebServer 3.5 | Pure Java `ServerSocket` + `ThreadPoolExecutor` |
| File streaming | GCDWebServer file response (256KB) | `RandomAccessFile` (256KB chunks) |
| Range / 206 | ✅ (GCDWebServer) | ✅ (single range, `RandomAccessFile.seek`) |
| Keep-alive | ✅ | ✅ (up to 100 req/conn, 5s idle) |
| Conditional GET | ✅ ETag/304 | ✅ ETag/304 |
| `start()`/`stop()` threading | serial GCD queue (off-main) | single-thread `controlExecutor` (off-bridge) |
| Max concurrent connections | GCDWebServer-managed | 32 (semaphore-gated, 503 when exceeded) |
| WiFi interface | `en0` / `en1` | `wlan0*` / `eth0` |
| Min version | iOS 13.0 | Android SDK 21 |
| Permissions | None required | `INTERNET`, `ACCESS_WIFI_STATE` (auto-merged) |

## Guaranteed transfer — client (downloader) guidance

The server now exposes everything a client needs to make transfers reliable. To **guarantee**
delivery, the downloading side (desktop app / browser / peer) should:

1. **List with metadata** — `GET /api/files` returns each file's `size` and `modified`. Treat
   `size` as the expected byte count.
2. **Resume on failure** — downloads are resumable. On an interrupted transfer, re-request the
   file with a `Range: bytes=<bytesAlreadyOnDisk>-` header; the server replies `206 Partial Content`
   and streams only the remainder. Append to the partial file instead of restarting from 0.
3. **Verify completeness** — after download, assert `bytesOnDisk === size` from the listing. A
   mismatch means truncation → retry (resume) with exponential backoff.
4. **Avoid stale reads** — pass the previously received `ETag` as `If-None-Match`; a `304` means
   the file is unchanged (skip re-download). A changed file returns `200` with a new `ETag`.

Example (Expo / React Native downloader, e.g. mobile-to-mobile):

```javascript
import * as FileSystem from 'expo-file-system';

async function downloadWithResume(fileUrl, dest, expectedSize, { retries = 5 } = {}) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    const resumable = FileSystem.createDownloadResumable(fileUrl, dest);
    try {
      await resumable.downloadAsync();             // resumes automatically if a .part exists
      const info = await FileSystem.getInfoAsync(dest);
      if (!expectedSize || info.size === expectedSize) return dest;  // verified
      // size mismatch → truncated, fall through to retry
    } catch (e) {
      // network drop — fall through to retry
    }
    await new Promise(r => setTimeout(r, Math.min(1000 * 2 ** attempt, 15000)));
  }
  throw new Error(`Download failed/verification mismatch: ${fileUrl}`);
}
```

For browsers, no client code is needed — `<a download>` / `fetch` against `/download/<path>`
already benefit from Range + keep-alive + revalidation transparently.

## License

ISC
