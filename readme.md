# Adobe Downloader

![Adobe Downloader 2.0.0](imgs/Adobe%20Downloader%202.0.0.png)

# **[English version](readme-en.md)**

## 使用须知

> ⚠️ 本仓库不支持任何 Pr 提交

**由于 2.1 版本重写了 Helper，所以最低支持版本不再为 macOS 12.0+**
**🍎仅支持 macOS 13.0+**

> **如果你也喜欢 Adobe Downloader, 或者对你有帮助, 请 Star 仓库吧 🌟, 你的支持是我更新的动力**
>
> 1. 在对Adobe产品进行安装前，系统必须存在 Adobe Setup 组件，否则无法使用安装功能，可通过程序内置的"设置"
     中进行下载，或前往[Adobe Creative Cloud](https://creativecloud.adobe.com/apps/download/creative-cloud)进行下载
> 2. 为了能够在下载后顺利安装，Adobe Downloader 需要对 Adobe 的 Setup
     程序做出修改，该过程由程序全自动，无需用户介入，非常感谢 [QiuChenly](https://github.com/QiuChenly)
     提供的解决方案
> 3. 如果在使用过程中遇到问题， 请通过 Telegram 联系我: [@X1a0He](https://t.me/X1a0He_bot)
> 4. ⚠️⚠️⚠️ **Adobe Downloader 中的所有 Adobe 应用均来自 Adobe 官方渠道，并非破解版本。**
> 5. ❌❌❌ **不要将下载目录设置为外接移动硬盘或者USB设备，这会导致出现权限问题，我并没有时间也没有耐心处理任何权限问题**

## 常见问题

**这里会不定时更新一些 issues 出现过的，并且有意义的问题**

### **[NEW] 关于 错误代码 和 Helper 的问题**

在 1.3.0 版本以前，由于没有获取到 root 权限或者更高的权限，导致非常多的操作都需要用户输入密码

所以，我们在 1.3.0 版本中引入了 Helper 的机制，只需要安装了 Helper 后续的 Setup 组件处理，产品安装均不再需要输入密码

也许你会在右上角看到相关提示，请放心，你的系统非常安全，这是因为 macOS 的 Helper 机制和签名的弹窗

如果你还担心存在问题，请找专业人士查阅相关代码，尽管这是徒劳

### 关于 setup 组件的问题

> 使用须知中强调了，如果需要使用安装功能，那么就必须对 Adobe 的 setup 组件进行修改处理，你可以在代码中找到

为什么要处理，因为不处理无法安装，会出现2700错误代码

> **setup处理是否需要用户手动处理？**

并不需要，Adobe Downloader已完成了全自动处理且备份 setup 组件的功能

<a href="https://star-history.com/#X1a0He/Adobe-Downloader&Timeline">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=X1a0He/Adobe-Downloader&type=Timeline&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=X1a0He/Adobe-Downloader&type=Timeline" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=X1a0He/Adobe-Downloader&type=Timeline" />
 </picture>
</a>

## 📔 最新日志

- 更多关于 App 的更新日志，请查看 [Update Log](update-log.md)

- 2025-11-22 更新日志

```markdown
1. 修复了清理工具执行清理时出现清理不全面的问题
2. 新增修复 Helper 的 sh 脚本和入口
3. 默认选中 SuperCafModels 包
4. 升级 Sparkle 到 2.8.1
```

### 语言支持

- [x] 中文
- [x] English

## ⚠️ 注意

**如果你对 Adobe Downloader 有任何优化建议或疑问，请提出 issue 或通过 Telegram 联系 [@X1a0He](https://t.me/X1a0He_bot)**

## ✨ 特点

- [x] 基本功能 📦
    - [x] Acrobat Pro 的下载
    - [x] 其他 Adobe 产品的下载
    - [x] 支持安装非 Acrobat 产品
    - [x] 支持多个产品同时下载
    - [x] 支持使用默认语言和默认目录
    - [x] 支持任务记录持久化
- [x] 安装功能 📦
- [x] 清理功能 🧹 (1.5.0新增)
    - [x] Adobe 应用程序
    - [x] Adobe Creative Cloud
    - [x] Adobe 偏好设置
    - [x] Adobe 缓存文件
    - [x] Adobe 许可文件
    - [x] Adobe 日志文件
    - [x] Adobe 服务
    - [x] Adobe 钥匙串
    - [x] Adobe 正版验证服务
    - [x] Adobe Hosts

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

- [QiuChenly/InjectLib](https://github.com/QiuChenly/InjectLib/)

## 👨🏻‍💻作者

Adobe Downloader © X1a0He

Released under GPLv3. Created on 2024.11.05.

> GitHub [@X1a0He](https://github.com/X1a0He/) \
> Telegram [@X1a0He](https://t.me/X1a0He_bot)
