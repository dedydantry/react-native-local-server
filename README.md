# react-native-local-server

A lightweight, zero-dependency local HTTP static file server for React Native. Built with pure native sockets (BSD sockets on iOS, Java ServerSocket on Android) — no third-party server libraries required.

Serves files from any local directory over HTTP with chunked streaming, CORS support, and built-in JSON APIs for file/directory listing.

## Features

- **Pure native implementation** — no embedded web server dependencies
- **Large file streaming** — 256KB chunked transfer, handles images/videos of any size
- **Cross-platform** — iOS (Objective-C) and Android (Java)
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
| Socket implementation | BSD sockets + GCD dispatch_source | Java `ServerSocket` + `ExecutorService` |
| File streaming | `NSFileHandle` (256KB chunks) | `BufferedInputStream` (256KB chunks) |
| WiFi interface | `en0` / `en1` | `wlan0` / `eth0` |
| Min version | iOS 13.0 | Android SDK 21 |
| Permissions | None required | `INTERNET`, `ACCESS_WIFI_STATE` (auto-merged) |

## License

ISC
