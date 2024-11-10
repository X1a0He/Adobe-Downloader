# Adobe Downloader

![preview](imgs/Adobe%20Downloader.png)

# **[English version](readme-en.md)**

## 使用须知

**🍎仅支持 macOS 12.0+**

> **如果你也喜欢 Adobe Downloader, 或者对你有帮助, 请 Star 仓库吧 🌟, 你的支持是我更新的动力**
>
> 1. 在对
     Adobe产品进行安装前，你必须先安装 [Adobe Creative Cloud](https://creativecloud.adobe.com/apps/download/creative-cloud)
     ，否则将无法使用本程序
> 2. 为了能够在下载后顺利安装，你需要对 Adobe 的 Setup 程序做出修改，非常感谢 [QiuChenly](https://github.com/QiuChenly)
     提供的解决方案
> 3. 如果在使用过程中遇到问题， 请通过 Telegram 联系我: [@X1a0He](https://t.me/X1a0He) , 或者使用 Python
     版本，非常感谢 [Drovosek01](https://github.com/Drovosek01)
     的 [adobe-packager](https://github.com/Drovosek01/adobe-packager)
> 4. ⚠️⚠️⚠️ **Adobe Downloader 中的所有 Adobe 应用均来自 Adobe 官方渠道，并非破解版本。**
> 5. ❌❌❌ **不要将下载目录设置为外接移动硬盘或者USB设备，这会导致出现权限问题，我并没有时间也没有耐心处理任何权限问题**
> 6. ❌❌❌ **由于权限原因，可能会在黑苹果上出现无法安装的问题**

## 🚀 安装

### 手动安装

请从 [Releases](https://github.com/X1a0He/Adobe-Downloader/releases) 页面下载最新版本。

### Homebrew

```shell
brew tap zach677/star && brew install adobedownloader
```

## 📔 最新日志

- 更多关于 App 的更新日志，请查看 [Update Log](update-log.md)

- 2024-11-09 23:00 更新日志

```markdown
1. 修复了初次启动程序时，默认下载目录为 "Downloads" 导致提示 你不能存储文件“ILST”，因为该宗卷是只读宗卷 的问题
2. 新的实现取代了 windowResizability 以适应 macOS 12.0+（可能）
3. 新增下载记录持久化功能(M1 Max macOS 15上测试正常，未测试其他机型)

PS: 此版本改动略大，如有bugs，请及时提出
```

### 语言支持

- [x] 中文
- [x] English

## ⚠️ 注意

**对于各位 SwiftUI 前辈来说，我只是一个 SwiftUI 新手，部分代码来自 Claude、OpenAI 和 Apple 等**
\
**如果你对 Adobe Downloader 有任何优化建议或疑问，请提出 issue 或通过 Telegram 联系 [@X1a0He](https://t.me/X1a0He)**

## ✨ 特点

- [x] 基本功能
    - [x] Acrobat Pro 的下载
    - [x] 其他 Adobe 产品的下载
    - [x] 支持安装非 Acrobat 产品
    - [x] 支持多个产品同时下载
    - [x] 支持使用默认语言和默认目录
    - [x] 支持任务记录持久化

## 👀 预览

### 浅色模式 & 深色模式

![light](imgs/preview-light.png)
![dark](imgs/preview-dark.png)

### 版本选择

![version picker](imgs/version.png)

### 语言选择

![language picker](imgs/language.png)

### 下载任务管理

![download management](imgs/download.png)

## 🔗 引用

- [Drovosek01/adobe-packager](https://github.com/Drovosek01/adobe-packager/)
- [QiuChenly/InjectLib](https://github.com/QiuChenly/InjectLib/)

## 👨🏻‍💻作者

Adobe Downloader © X1a0He

Released under GPLv3. Created on 2024.11.05.

> GitHub [@X1a0He](https://github.com/X1a0He/) \
> Telegram [@X1a0He](https://t.me/X1a0He)
