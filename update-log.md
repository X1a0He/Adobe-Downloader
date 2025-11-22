# Change Log

## 2025-11-22 更新日志

[//]: # (2.1.4)
```markdown
1. 修复了清理工具执行清理时出现清理不全面的问题
2. 新增修复 Helper 的 sh 脚本和入口
3. 默认选中 SuperCafModels 包
4. 升级 Sparkle 到 2.8.1

====================

1. Fixed an issue where the cleanup tool would not clean up all files.
2. Added a sh script and entry for repairing Helper.
3. Selected SuperCafModels package by default.
4. Upgraded Sparkle to 2.8.1.
```

## 2025-08-17 更新日志

[//]: # (2.1.3)
```markdown
1. 垃圾 SMAppService 赶紧滚，回退 SMJobBless Helper
2. 修复了安装时 Helper 权限不足导致 103 错误的问题

====================

1. Back to SMJobBless Helper.
2. Fixed an issue where Helper permissions were insufficient during installation.
```

## 2025-08-11 更新日志

[//]: # (2.1.2)
```markdown
1. 修复了Helper无法连接的问题
2. 修复了自定义下载永远是最新版本的问题
3. 新增开关用于在删除任务时同时删除本地文件
4. 修复了Helper不会自动更新的问题

====================

1. Fixed an issue where Helper could not reconnect.
2. Fixed an issue where the custom download is always the latest version.
3. Added a switch to delete local files at the same time when deleting tasks.
4. Fixed an issue where Helper would not automatically update.
```

## 2025-07-22 更新日志

[//]: # (2.1.1)
```markdown
1. 修复了无法下载 Acrobat 的问题

====================

1. Fixed an issue where Acrobat products could not be downloaded.
```

## 2025-07-20 更新日志

[//]: # (2.1)
```markdown
1. 新增安装前终止 Setup 的特性
2. 新增并发下载数控制
3. 重写版本选择界面，采用 NavigationStack 的特性支持版本选择和自定义包选择
4. 重写下载逻辑，支持线程池 + 分片的单任务多个包同时下载
5. 重写 Helper 逻辑，使用 macOS 13.0+ 的 SMAppService 新特性
6. 调整 Helper 链接状态的呼吸灯表现

====================

1. Added feature to cancel Setup before installation.
2. Added concurrency control for downloads.
3. Rewritten version selection interface using NavigationStack with package customization.
4. Rewritten download logic with thread pooling + segmented downloading for parallel package fetching.
5. Rewritten Helper logic using SMAppService \(macOS 13.0+\).
6. Refined breathing light indicator for Helper connection status.
```

## 2025-04-23 更新日志

[//]: # (2.0.2)
```markdown
1. 修复了 Intel 机型下依赖包判断遇到 osx10 被误判为 arm 导致下载错误的问题
2. 修复了设置界面上方的文字显示问题
3. 调整下载管理界面的高度: 500 -> 600
4. 新增下载任务复制所有产品和包列表信息
5. 优化产品 Substance Alchemist 的显示问题

====================

1. Fixed an issue where dependency package detection on Intel-based models mistakenly identified osx10 as ARM architecture, leading to incorrect downloads.
2. Resolved text display issues in the settings interface header.
3. Adjusted the height of the download management interface from 500 to 600.
4. Added functionality to copy all product and package list information in download tasks.
5. Optimized display handling for the product Substance Alchemist.
```

## 2025-04-06 更新日志

[//]: # (2.0.1)
```markdown
1. 修复了选择任意版本的情况下仍下载最新版本的问题
2. 修复了在 Intel 机型下下载包为 arm64 的问题
3. 修复了产品包依赖下载架构不一致的问题
4. 新增了自定义设置页面
5. 大幅优化整体渲染性能，解决拖动界面造成卡顿的问题

====================

1. Fixed an issue where the latest version would still be downloaded even when selecting any specific version
2. Fixed an issue where Intel-based devices were downloading arm64 packages
3. Fixed inconsistent architecture downloads for product package dependencies
4. Added a custom settings view
5. Significantly optimized overall rendering performance, resolving interface lag during dragging
```

## 2025-03-27 更新日志

[//]: # (2.0.0)
```markdown
1. 全新UI设计，引入了毛玻璃背景
2. 当鼠标移入产品卡片时会有新的交互体验
3. 产品卡片显示优化，优化可用版本，依赖数量的显示
4. 产品卡片显示优化，新增最低系统版本和模块数量显示
5. API版本切换UI优化
6. ToolBar显示优化
7. 产品滚动显示优化
8. 版本选择显示优化，新增更加详细的产品版本信息
9. 版本选择显示优化，新增显示组件详细版本和buildGuid信息
10. 版本选择显示优化，在 DEBUG 模式下，会展示更多的信息
11. 下载管理显示优化，优化了下载管理页面的UI展示
12. 下载管理显示优化，引入了更加明显的按钮设计
13. 下载管理显示优化，对任务下载的进度与包列表显示进行了优化，现在，你可以在对应的包列表中进行复制相关 BuildGuid
14. 完全重构产品加载逻辑，遵循 Adobe Creative Cloud 的数据结构
15. 完全重构主产品与依赖包之间的关系
16. 优化产品安装逻辑，大幅减少由芯片架构，系统版本带来的安装失败问题
17. 新增安装错误的日志详情，当遇到安装错误的时候，显示更详细的错误代码与错误原因
18. 修改安装判断逻辑，当 Setup 未被处理时，不再显示相关安装选项
19. 修复了点击重新处理 Setup 时，程序执行了下载与处理的问题
20. 修复了 Setup 组件处理失败的问题
21. 优化 Helper 的重新安装逻辑
22. 新增系统信息展示

PS: ✅ 2.0.0 版本将继续开源

====================

1. Redesigned UI with blurred background effects
2. New hover interactions for product cards
3. Enhanced product card display showing available versions and dependency counts
4. Added system requirements with minimum version and module count indicators
5. Improved API version switching interface
6. Optimized toolbar layout and visual presentation
7. Smoother scrolling for product listings
8. Detailed version information added to version selection
9. Component-specific version details now include buildGuid identifiers
10. DEBUG mode enhancements revealing extended diagnostic information
11. Streamlined download manager with redesigned user interface
12. Prominent action buttons for better download management
13. Enhanced task monitoring with copyable buildGuid support in package lists
14. Complete rewrite of product loading logic following Adobe Creative Cloud data architecture
15. Revised dependency management between core products and components
16. Stability improvements reducing architecture/system version-related installation failures
17. Detailed error logging with specific error codes and causes
18. Smart installation flow hiding options when Setup is unprocessed
19. Fixed unexpected download behavior during Setup reprocessing
20. Resolved Setup component processing errors
21. Optimized Helper reinstallation workflow
22. New system information panel added
```

## 2025-02-06 更新日志

[//]: # (1.5.1)

```markdown
1. 修复了当任务下载完成后，退出程序重新进入时，状态显示非已完成的问题
2. 修复了某种情况下，任务会被多次添加的问题
3. 修复了 Acrobat 产品错误显示 "命令行安装" 按钮的问题
4. 修复了当本地存在了已下载的文件，但持久化数据被删除后，需要每次点击 "使用现有程序" 才会创建任务的问题
5. 修复了点击 "使用现有程序" 创建完任务后不会创建持久化文件的问题
6. 在 DEBUG 模式下，添加了 "查看持久化文件" 的按钮

PS: ⚠️ 1.5.x 版本将会是最后一个开源版本，请知晓

====================

1. Fixed the issue where after the task download is completed, the program will prompt that it has been paused when
   re-entering the program
2. Fixed an issue where tasks were loaded multiple times.
3. Fixed an issue where Acrobat products displayed the "Command Line" button incorrectly.
4. Fixed the issue that when the downloaded file exists locally but the persistent data is deleted, the task needs to be
   created every time by clicking "Use existing program"
5. Fixed the issue that the persistent file will not be created after clicking "Use existing program" to create the task
6. Add a 'View Persistent Files' button to download progress in DEBUG mode

PS: ⚠️ 1.5.x version will be the last open source version, please be aware
```

## 2025-02-05 更新日志

[//]: # (1.5.0)

```markdown
1. 修复部分情况下，Helper 无法重新连接的情况
2. 修复部分情况下，重新安装程序以及重新安装 Helper 的无法连接的情况
3. 调整 X1a0He CC 部分，1.5.0 版本可以选择 "下载并处理" 和 "仅下载"
4. 调整了部分 Setup 组件的内容翻译
5. 程序设置页中添加 「清理工具」 和 「常见问题」功能
6. 程序设置页中，添加当前版本显示

PS: 当前版本添加的 「清理工具」功能为实验性功能，如有清理不全，请及时反馈
PS: ⚠️ 1.5.x 版本将会是最后一个开源版本，请知晓

====================

1. Fixed the issue of Helper not being able to reconnect in some cases
2. Fixed the issue of not being able to reconnect after reinstalling the program and reinstalling Helper
3. Adjusted the content translation of X1a0He CC, version 1.5.0 can choose "Download and Process" and "Only Download"
4. Adjusted the translation of some Setup component content
5. Added "Cleanup Tool" and "Common Issues" functions in the program settings page
6. Added the current version display in the program settings page

PS: The "Cleanup Tool" function in the current version is an experimental feature. If some files are not cleaned up,
please feedback in time
PS: ⚠️ 1.5.x version will be the last open source version, please be aware
```

## 2025-01-26 更新日志

[//]: # (1.4.1)

```markdown
1. 修复安装失败并提示错误代码 255 的问题
2. 增加了一个新特性，在 Debug 模式下，并不会检测 CC 组件的处理情况和备份情况
3. 调整了部分安装提示文字的翻译

====================

1. Fixed the issue of installation failure with error code 255.
2. Added a new feature, in Debug mode, the handling and backup status of the CC component will not be checked.
3. Adjusted the translation of some installation prompt messages.
```

## 2025-01-14 17:45 更新日志

[//]: # (1.4.0)

```markdown
1. 支持窗口调整大小，适配屏幕更小的设备
2. 修正了部分视图下的拼写错误
3. 对 Helper 进行了进一步的完善

PS: Adobe Downloader 已进入了稳定阶段，大部分情况下均可正常下载
====================

1. Added support for window resizing to better accommodate smaller screens.
2. Fixed spelling errors in certain views.
3. Further improvements made to the Helper functionality.

PS: Adobe Downloader has reached a stable phase and is generally capable of performing downloads under most
conditions.
```

## 2024-11-19 00:55 更新日志

[//]: # (1.3.1)

```markdown
1. 模拟官方 Adobe Creative Cloud 的包依赖下载逻辑
2. 由于上述更新，修复了某些包下载数量仍然不足的问题
3. 修复了当已存在 HDBox 和 IPCBox 的时候，下载 X1a0He CC 组件后，并不会替换掉原来的组件的问题
4. 修复了 Acrobat 产品在暂停和取消时仍处于下载状态的问题
5. 底部增加产品数量显示，居中显示警示标语
6. 增加部分语言选择
7. 优化了版本选择页面的排序展示
8. 优化了产品处理和解析速度，弃用 xml 处理和解析，采用 json 的形式处理

PS: M1 Max上已测试大部份产品正常下载并安装，Intel未测试，有问题请提issues
====================

1. Simulate the package dependency download logic of the official Adobe Creative Cloud
2. Due to the above updates, the problem of insufficient download quantity of some packages has been fixed
3. Fixed when HDBox and IPCBox already exist, the problem that the original components will not be replaced after
   downloading X1a0He CC components
4. Fixed the problem that Acrobat products are still in downloading status when paused and canceled
5. Add product quantity display at the bottom and display warning slogan in the center
6. Add some language selections
7. Optimize the sorting display of the version selection page
8. Optimize product processing and parsing speed, abandon xml processing and parsing, and use json processing

PS: Most products have been tested on M1 Max and downloaded and installed normally, but Intel has not been tested. If
you have any questions, please raise issues
```

## 2024-11-16 14:30 更新日志

[//]: # (1.3.0)

```markdown
1. 新增可选API版本 (v4, v5, v6)【更老的API意味着更长的等待时间】
2. 引入 Privilege Helper 来处理所有需要权限的操作
3. 修改从 Github 下载 Setup 组件功能，改为从官方下载简化版CC，称为 X1a0He CC
4. 调整 CC 组件备份与处理状态检测，分离二者的检测机制
5. 移除了安装日志显示
6. 调整 Setup 组件版本号的获取方式
7. 修复了当任务下载完成后，AppCardView 仍显示下载中的问题
8. 修复了 Intel 架构下，安装时因架构文件错误出现错误代码 107 的问题
9. 修复了当初次或某种情况下安装会导致进度卡住但事实上已经安装完成的问题
10. 修复了文件包下载不完全或不完整的问题
11. 新增重置程序配置，建议该版本先运行一次重置程序

PS: CC 组件的来源均为 Adobe Creative Cloud 官方提取，可随时下载到最新版，但处理可能会失败
====================

1. Added optional API versions (v4, v5, v6) [Older API means longer waiting time]
2. Introduced Privilege Helper to handle all operations that require permissions
3. Modified the function of downloading the Setup component from Github, and changed it to downloading the simplified
   version of CC from the official website, called X1a0He CC
4. Adjusted the detection of CC component backup and processing status, and separated the detection mechanism of the two
5. Removed the installation log display
6. Adjusted the method of obtaining the version number of the Setup component
7. Fixed the problem that AppCardView still shows downloading after the task download is completed
8. Fixed the problem that error code 107 appears during installation due to architecture file errors under Intel
   architecture
9. Fixed the problem that the progress is stuck when installing for the first time or under certain circumstances, but
   in fact the installation has been completed
10. Fixed the problem of incomplete or incomplete file package download
11. Added reset program configuration, it is recommended to run the reset program once in this version

PS: CC components are all from Adobe Creative Cloud official extraction, you can download the latest version at any
time, but the processing may fail
```

## 2024-11-11 21:00 更新日志

[//]: # (1.2.0)

```markdown
1. 调整程序启动时 sheet 的弹出顺序
2. 设置中添加了 Setup 组件的检测和版本号检测，支持在设置中重新备份与处理
3. 调整 Setup 组件的检测，不再需要完整安装 Adobe Creative Cloud
4. 增加了安装前 Setup 组件是否已处理的判断，未处理 Setup 组件，无法使用安装功能
5. 调整 Setup 组件检测弹窗界面
6. 增加从 GitHub 中下载 Setup 组件，无法访问 GitHub 的用户可能会出现无法下载的问题

PS: Setup 组件的来源均为 Adobe Creative Cloud 官方提取，可能存在更新不及时
====================

1. Adjust the order of sheet pop-up when the program starts
2. Added detection of Setup components and version number detection in settings, supporting re-backup and processing in
   settings
3. Adjusted detection of Setup components, no longer requiring full installation of Adobe Creative Cloud
4. Added judgment of whether Setup components have been processed before installation. If Setup components are not
   processed, the installation function cannot be used
5. Adjusted the pop-up interface of Setup component detection
6. Added downloading of Setup components from GitHub. Users who cannot access GitHub may encounter problems with
   download failure

PS: The sources of Setup components are all extracted from Adobe Creative Cloud, so they may not be updated in time.
```

<img width="562" alt="image" src="https://github.com/user-attachments/assets/47159318-a7b0-46db-b6af-4e8926a6733c">

<img width="630" alt="image" src="https://github.com/user-attachments/assets/9dbec07d-d280-4107-b6cf-5ad7cab8158e">

<img width="880" alt="image" src="https://github.com/user-attachments/assets/5d1fcd81-7ac6-41db-a8d3-5ff2c116056e">

## 2024-11-09 23:00 更新日志

[//]: # (1.1.0)

```markdown
1. 修复了初次启动程序时，默认下载目录为 "Downloads" 导致提示 你不能存储文件“ILST”，因为该宗卷是只读宗卷 的问题
2. 新的实现取代了 windowResizability 以适应 macOS 12.0+（可能）
3. 新增下载记录持久化功能(M1 Max macOS 15上测试正常，未测试其他机型)

PS: 此版本改动略大，如有bugs，请及时提出
====================

1. Fixed the issue that when launching the program for the first time, the default directory is "Downloads", which
   causes a download error message
2. New implementation replaces windowResizability to adapt to macOS 12.0+ (Maybe)
3. Added task record persistence(Tested normally on M1 Max macOS 15, other models not tested)

PS: This version has been slightly changed. If there are any bugs, please report them in time.
```

## 2024-11-07 21:10 更新日志

[//]: # (1.0.1)

```markdown
1. 修复了当系统版本低于 macOS 14.6 时无法打开程序的问题，现已支持 macOS 13.0 以上
2. 增加 Sparkle 用于检测更新
3. 当默认目录为 未选择 时，将 下载 文件夹作为默认目录
4. 当通过 Adobe Downloader 安装遇到权限问题时，提供终端命令让用户自行安装
5. 调整了文件已存在的 UI 显示
6. 修复了在任务下载中，已下载包与总包数量不更新的问题

====================

1. Support macOS 13.0 and above
2. Added Sparkle for checking update
3. When the default directory is not selected, the Downloads folder will be used as the default directory
4. When installing via Adobe Downloader and encountering permission issues, provide terminal commands to allow users to
   install by themselves
5. Adjusted the UI display of existing files
6. Fixed the issue where the number of downloaded packages and total packages was not updated during task download
```

<img width="1064" alt="image" src="https://github.com/user-attachments/assets/84f3f1de-a429-45ca-9b29-948234b4fcdb">

<img width="530" alt="image" src="https://github.com/user-attachments/assets/7a22ea27-449b-42cf-8142-fce1215c5d12">

<img width="427" alt="image" src="https://github.com/user-attachments/assets/403b20db-4014-4645-8833-3616390b17fb">

<img width="880" alt="image" src="https://github.com/user-attachments/assets/b6b04cd9-bfdf-4cdd-b14c-6dcd48b376a7">

## 2024-11-06 15:50 更新日志

```markdown
1. 增加程序首次启动时的默认配置设定与提示
2. 增加可选架构下载，请在设置中进行选择
3. 修复了版本已存在检测错误的问题 (仅检测文件是否存在，并不会检测是否完整)
4. 移除主界面的语言选择和目录选择，移动到了设置中
5. 版本选择页面增加架构提示
6. 移除了安装程序的机制，现在不会再生成安装程序
7. 增加了Adobe Creative Cloud安装检测，未安装前无法使用

====================

1. Added default configuration settings and prompts when the program is started for the first time
2. Added optional architecture downloads, please select in settings
3. Fixed the problem of version detection error (only checks whether the file exists, not whether it is complete)
4. Removed the language selection and directory selection on the main interface and moved them to settings
5. Added architecture prompts on the version selection page
6. Removed the installer mechanism, and now no installer will be generated
7. Added Adobe Creative Cloud installation detection, which cannot be used before installation
```

## 2024-11-05 21:15 更新日志

```markdown
1. 增加Intel机型的Setup处理，感谢@aronychen

====================

1. Added Setup processing for Intel chips, thanks @aronychen
```

----

## 2024-11-05 15:05 更新日志

```markdown
1. 初始化仓库

====================

1. Init repo
```