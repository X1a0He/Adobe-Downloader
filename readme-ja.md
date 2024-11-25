# Adobe Downloader

![preview](imgs/Adobe%20Downloader.png)

# **[英語版](readme-en.md)**

## 使用前に

**🍎macOS 12.0+ のみ対応。**

> **Adobe Downloader が気に入った場合、または役立つ場合は、Star🌟をお願いします。**
>
> 1. Adobe 製品をインストールする前に、システムに Adobe Setup コンポーネントが存在する必要があります。そうでない場合、インストール機能は動作しません。プログラム内の「設定」からダウンロードするか、[Adobe Creative Cloud](https://creativecloud.adobe.com/apps/download/creative-cloud) からダウンロードできます。
> 2. ダウンロード後にスムーズにインストールするために、Adobe Downloader は Adobe の Setup プログラムを変更する必要があります。このプロセスはプログラムによって完全に自動化されており、ユーザーの介入は不要です。[QiuChenly](https://github.com/QiuChenly) に感謝します。
> 3. 問題が発生した場合は、慌てずに Telegram で [@X1a0He](https://t.me/X1a0He) に連絡するか、Python バージョンを使用してください。[Drovosek01](https://github.com/Drovosek01) の [adobe-packager](https://github.com/Drovosek01/adobe-packager) に感謝します。
> 4. ⚠️⚠️⚠️ **Adobe Downloader に含まれるすべての Adobe アプリは公式の Adobe チャネルからのものであり、クラックされたバージョンではありません。**
> 5. ❌❌❌ **外付けハードドライブや USB を使用しないでください。これにより、権限の問題が発生します。権限の問題については解決する時間がありません。**

## FAQ

**このセクションでは、定期的に意味のある問題を更新します。**

### **[NEW] エラーコードと Helper について**

バージョン 1.3.0 以前では、root 権限やそれ以上の権限が取得されていないため、多くの操作でユーザーがパスワードを入力する必要がありました。

そのため、バージョン 1.3.0 では Helper メカニズムを導入しました。Helper をインストールするだけで、その後の Setup コンポーネントの処理や製品のインストールでパスワードを入力する必要がなくなります。

右上に関連するプロンプトが表示される場合がありますが、システムは非常に安全です。これは macOS の Helper メカニズムと署名されたポップアップウィンドウのおかげです。

問題が心配な場合は、専門家にコードを確認してもらってください。無駄ですが。

### **関連するエラーコードの説明**

- 2700: Setup コンポーネントの処理が失敗しない限り、発生する可能性は低いです。
- 107: ダウンロードしたファイルのアーキテクチャがシステムのアーキテクチャと一致しないか、インストールファイルが破損しています。バージョン 1.3.0 では発生する可能性は低いです。
- 103: 権限の問題があります。バージョン 1.3.0 では発生する可能性は低いです。
- 182: ファイルが不完全または破損しています。バージョン 1.3.0 では発生する可能性は低いです。
- 133: システムディスクの空き容量が不足しています。
- -1: Setup コンポーネントが処理されていないか、処理に失敗しました。開発者に連絡してください。
- 195: ダウンロードした製品が現在のシステムをサポートしていません。

### Setup コンポーネントに関する質問

> 使用説明書には、インストール機能を使用するには Adobe の setup コンポーネントを変更する必要があると記載されています。詳細はコードにあります。

なぜこれが必要なのですか？変更しないと、エラーコード 2700 でインストールが失敗します。

> **setup の変更にはユーザーの介入が必要ですか？**

いいえ、Adobe Downloader は setup コンポーネントの処理を自動化しており、バックアップも行います。プロンプトが表示されたらパスワードを入力するだけです。

## 📔最新のログ

- 過去の更新ログについては、[Update Log](update-log.md) をご覧ください。

- 2024-11-19 00:55 更新ログ

```markdown
1. 公式の Adobe Creative Cloud のパッケージ依存関係のダウンロードロジックをシミュレート
2. 上記の更新により、一部のパッケージのダウンロード数が不足している問題を修正
3. HDBox と IPCBox が既に存在する場合、X1a0He CC コンポーネントをダウンロードした後、元のコンポーネントが置き換えられない問題を修正
4. Acrobat 製品が一時停止およびキャンセルされたときに、ダウンロード状態のままになる問題を修正
5. 底部に製品数の表示を追加し、中央に警告スローガンを表示
6. 一部の言語選択を追加
7. バージョン選択ページのソート表示を最適化
8. 製品の処理と解析速度を最適化し、xml 処理と解析を廃止し、json 処理を採用

PS: ほとんどの製品は M1 Max でテストされ、正常にダウンロードおよびインストールされましたが、Intel ではテストされていません。問題がある場合は、issues を提起してください。
```

### 言語対応

- [x] 中国語
- [x] 英語

## ⚠️ 警告

**SwiftUI の先輩方へ、私は SwiftUI の初心者です。一部のコードは Claude、OpenAI、Apple などからのものです。**
\
**Adobe Downloader に関する最適化の提案や質問がある場合は、issue を提出するか、Telegram で [@X1a0He](https://t.me/X1a0He) に連絡してください。**

## ✨ 機能

- [x] 基本機能
    - [x] Acrobat Pro のダウンロード
    - [x] その他の Adobe 製品のダウンロード
    - [x] Acrobat 以外の製品のインストールをサポート
    - [x] 複数の製品の同時ダウンロードをサポート
    - [x] デフォルトの言語とデフォルトのディレクトリの使用をサポート
    - [x] タスク記録の永続化をサポート

## 👀 プレビュー

### ライトモード & ダークモード

![light](imgs/preview-light.png)
![dark](imgs/preview-dark.png)

### バージョン選択

![version picker](imgs/version.png)

### 言語選択

![language picker](imgs/language.png)

### ダウンロード管理

![download management](imgs/download.png)

## 🔗 参考文献

- [Drovosek01/adobe-packager](https://github.com/Drovosek01/adobe-packager/)
- [QiuChenly/InjectLib](https://github.com/QiuChenly/InjectLib/)

## 👨🏻‍💻作者

Adobe Downloader © X1a0He

GPLv3 の下でリリース。2024.11.05 に作成。

> GitHub [@X1a0He](https://github.com/X1a0He/) \
> Telegram [@X1a0He](https://t.me/X1a0He)
