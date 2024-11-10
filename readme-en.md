# Adobe Downloader

![preview](imgs/Adobe%20Downloader.png)

# **[中文版本](readme.md)**

## Before Use

**🍎Only for macOS 12.0+.**

> **If you like Adobe Downloader, or it helps you, please Star🌟 it.**
>
> 1. Before proceeding with the installation, make sure you have
     installed [Adobe Creative Cloud](https://creativecloud.adobe.com/apps/download/creative-cloud)
> 2. In order to successfully install after downloading, you need to modify the Adobe Setup program. Thanks
     to [QiuChenly](https://github.com/QiuChenly)
     for providing the installation solution
> 3. If you encounter any problems, don't panic, contact [@X1a0He](https://t.me/X1a0He) on Telegram or use the Python
     version. Many thanks to [Drovosek01](https://github.com/Drovosek01) for
     the [adobe-packager](https://github.com/Drovosek01/adobe-packager)
> 4. ⚠️⚠️⚠️ **All Adobe apps in Adobe Downloader are from official Adobe channels and are not cracked versions.**
> 5. ❌❌❌ **Do not use an external hard drive or any USB to store it, as this will cause permission issues, I do not have
     the patience to solve any about permission issues**
> 6. ❌❌❌ **Due to permission reasons, there may be problems with installation on hackintosh**

## 🚀 Install

### Manually Install

Download the latest version from [Releases](https://github.com/X1a0He/Adobe-Downloader/releases)

### Homebrew

```shell
brew tap zach677/star && brew install adobedownloader
```

## 📔Latest Log

- For historical update logs, please go to [Update Log](update-log.md)

- 2024-11-09 23:00 Update Log

```markdown
1. Fixed the issue that when launching the program for the first time, the default directory is "Downloads", which
   causes a download error message
2. New implementation replaces windowResizability to adapt to macOS 12.0+ (Maybe)
3. Added task record persistence(Tested normally on M1 Max macOS 15, other models not tested)

PS: This version has been slightly changed. If there are any bugs, please report them in time.
```

### Language friendly

- [x] Chinese
- [x] English

## ⚠️ Warning

**For all the SwiftUI seniors, I am just a SwiftUI newbie, some of the code comes from Claude, OpenAI and Apple, etc.**
\
**If you have any optimization suggestions or questions about Adobe Downloader, please open an issue or contact @X1a0He
via Telegram.**

## ✨ Features

- [x] Basic Functionality
    - [x] Download Acrobat Pro
    - [x] Download other Adobe products
    - [x] Support installation of non-Acrobat products
    - [x] Support multiple products download at the same time
    - [x] Supports using default language and default directory
    - [x] Support task record persistence

## 👀 Preview

### Light Mode & Dark Mode

![light](imgs/preview-light.png)
![dark](imgs/preview-dark.png)

### Version Picker

![version picker](imgs/version.png)

### Language Picker

![language picker](imgs/language.png)

### Download Management

![download management](imgs/download.png)

## 🔗 References

- [Drovosek01/adobe-packager](https://github.com/Drovosek01/adobe-packager/)
- [QiuChenly/InjectLib](https://github.com/QiuChenly/InjectLib/)

## 👨🏻‍💻Author

Adobe Downloader © X1a0He

Released under GPLv3. Created on 2024.11.05.

> GitHub [@X1a0He](https://github.com/X1a0He/) \
> Telegram [@X1a0He](https://t.me/X1a0He)
