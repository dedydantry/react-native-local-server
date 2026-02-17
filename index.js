import { NativeModules, Platform } from 'react-native';

const LINKING_ERROR =
  `The package 'react-native-local-server' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

const LocalServer = NativeModules.LocalServer
  ? NativeModules.LocalServer
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

export default class StaticServer {
  constructor(port = 8080, root = '', options = {}) {
    this.port = port;
    this.root = root;
    this.localOnly = options.localOnly || false;
    this._url = null;
    this._running = false;
  }

  /**
   * Start the static file server.
   * @returns {Promise<string>} The URL of the running server (e.g. "http://192.168.1.10:8080")
   */
  async start() {
    if (this._running) {
      return this._url;
    }
    const url = await LocalServer.start(this.port, this.root, this.localOnly);
    this._url = url;
    this._running = true;
    return url;
  }

  /**
   * Stop the static file server.
   * @returns {Promise<void>}
   */
  async stop() {
    if (!this._running) return;
    await LocalServer.stop();
    this._running = false;
    this._url = null;
  }

  /**
   * Check if the server is running.
   * @returns {Promise<boolean>}
   */
  async isRunning() {
    const running = await LocalServer.isRunning();
    this._running = running;
    return running;
  }

  /**
   * Get the URL of the running server.
   * @returns {string|null}
   */
  getURL() {
    return this._url;
  }

  /**
   * Get the API URL that returns all files as JSON.
   * Response format: { success, root, server, total, files: [{ name, path, url, size, mime, ext, modified }] }
   * Each file's `url` points to /download/<path> which triggers a file download.
   * @returns {string|null}
   */
  getFilesAPIUrl() {
    if (!this._url) return null;
    return `${this._url}/api/files`;
  }

  /**
   * Fetch all files in the server root directory as JSON.
   * @returns {Promise<{ success: boolean, root: string, server: string, total: number, files: Array<{ name: string, path: string, url: string, size: number, mime: string, ext: string, modified: number }> }>}
   */
  async getFiles() {
    if (!this._url) throw new Error('Server is not running');
    const response = await fetch(`${this._url}/api/files`);
    return response.json();
  }

  /**
   * Get the download URL for a specific file (relative path from root).
   * @param {string} relativePath - e.g. "photos/image.png"
   * @returns {string|null}
   */
  getDownloadURL(relativePath) {
    if (!this._url) return null;
    const encoded = encodeURIComponent(relativePath).replace(/%2F/g, '/');
    return `${this._url}/download/${encoded}`;
  }

  /**
   * Get the API URL for listing a directory's contents.
   * @param {string} [dirPath='/'] - Relative directory path from server root
   * @returns {string|null}
   */
  getDirAPIUrl(dirPath = '/') {
    if (!this._url) return null;
    if (!dirPath || dirPath === '/') {
      return `${this._url}/api/dir`;
    }
    const encoded = encodeURIComponent(dirPath).replace(/%2F/g, '/');
    return `${this._url}/api/dir/${encoded}`;
  }

  /**
   * List contents of a directory (non-recursive). Returns folders and files.
   * @param {string} [dirPath='/'] - Relative directory path from server root
   * @returns {Promise<{ success: boolean, path: string, server: string, total: number, items: Array<{ name: string, path: string, type: 'directory'|'file', children?: number, size?: number, mime?: string, ext?: string, url?: string, download?: string, modified?: number }> }>}
   */
  async getDir(dirPath = '/') {
    if (!this._url) throw new Error('Server is not running');
    const apiUrl = this.getDirAPIUrl(dirPath);
    const response = await fetch(apiUrl);
    return response.json();
  }

  /**
   * Get the URL to access a file or directory on the server.
   * @param {string} relativePath - e.g. "event-slug/photo.png"
   * @returns {string|null}
   */
  getFileURL(relativePath) {
    if (!this._url) return null;
    const encoded = encodeURIComponent(relativePath).replace(/%2F/g, '/');
    return `${this._url}/${encoded}`;
  }

  /**
   * Get the local IP address of the device.
   * @returns {Promise<string>}
   */
  static async getIPAddress() {
    return LocalServer.getIPAddress();
  }
}
