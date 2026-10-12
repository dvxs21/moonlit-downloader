# Moonlit Downloader

A small Windows app for downloading YouTube videos in HD with audio. Paste a link, pick a quality, and the file lands in your Downloads folder. The window shows an animated moonlit forest whose leaves react to the mouse.

![icon](icon.ico)

## Requirements

- Windows 10/11 with Microsoft Edge or Google Chrome
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [ffmpeg](https://ffmpeg.org/), installed via winget:

```powershell
winget install yt-dlp.yt-dlp
winget install Gyan.FFmpeg
```

## Run

Double-click `Launch.bat` or run:

```powershell
powershell -ExecutionPolicy Bypass -File app.ps1
```

`app.ps1` starts a tiny local server on `127.0.0.1:48721` and opens `index.html` in an app-style browser window. Closing the window stops the server.

Quality options: 720p, 1080p (default), 1440p, 4K, or audio-only MP3.

## Notes

Only download videos you have the right to download. Respect YouTube's terms of service and copyright.
