def generate_xml(changelog_cn, changelog_en, ps_cn, ps_en):
    xml_template = """
    <description>
        <![CDATA[
            <style>ul{{margin-top: 0;margin-bottom: 7;padding-left: 18;}}</style>
            <h4>Adobe Downloader 更新日志: </h4>
            <ul>
                {changelog_cn}
            </ul>
            <h4>PS: {ps_cn}</h4>
            <hr>
            <h4>Adobe Downloader Changes: </h4>
            <ul>
                {changelog_en}
            </ul>
            <h4>PS: {ps_en}</h4>
        ]]>
    </description>
    """

    changelog_cn_list = "\n".join([f"<li>{item}</li>" for item in changelog_cn])
    changelog_en_list = "\n".join([f"<li>{item}</li>" for item in changelog_en])

    return xml_template.format(
        changelog_cn=changelog_cn_list,
        changelog_en=changelog_en_list,
        ps_cn="<br>".join(ps_cn),
        ps_en="<br>".join(ps_en)
    )


def parse_input(text):
    sections = text.split("====================")

    if len(sections) < 2:
        raise ValueError("输入格式错误，必须包含 '====================' 作为分隔符")

    cn_lines = [line.strip() for line in sections[0].split("\n") if line.strip()]
    en_lines = [line.strip() for line in sections[1].split("\n") if line.strip()]

    changelog_cn, ps_cn, changelog_en, ps_en = [], [], [], []

    for line in cn_lines:
        if line.startswith("PS:"):
            ps_cn.append(line.replace("PS: ", ""))
        else:
            changelog_cn.append(line)

    for line in en_lines:
        if line.startswith("PS:"):
            ps_en.append(line.replace("PS: ", ""))
        else:
            changelog_en.append(line)

    return changelog_cn, changelog_en, ps_cn, ps_en


def main():
    txt = """1. 全新的下载机制，Adobe Downloader 对下载机制进行了进一步完善，引入了加载项单独下载功能
2. 全新的产品安装机制，Adobe Downloader 抛弃了原有的 Setup 组件依赖，采用新的安装引擎，支持所有产品的全量安装和增量安装，并引入了加载项单独安装功能
3. 全新的产品卸载机制，Adobe Downloader 引入了加载项卸载功能，你可以对某个产品的加载项进行单独卸载
4. 得益于全新的产品安装机制，你可以在 Adobe Creative Cloud 中找到通过 Adobe Downloader 安装的所有产品，包括依赖项也能够被正确识别
5. 适配 macOS 27，并支持 Liquid Glass 风格，带来更加丰富的 UI 界面
6. 更多 Adobe Downloader 3.0 新特性，等待你来体验

====================

1. Introduced a brand-new download mechanism. Adobe Downloader further improves the download workflow and now supports downloading add-ons
separately.
2. Introduced a brand-new product installation mechanism. Adobe Downloader no longer depends on the original Setup component and now uses a new
installation engine, supporting full and incremental installation for all products, as well as separate add-on installation.
3. Introduced a brand-new product uninstallation mechanism. Adobe Downloader now supports uninstalling add-ons separately for a specific product.
4. Thanks to the new installation mechanism, all products installed through Adobe Downloader can now be found in Adobe Creative Cloud, including
correctly recognized dependencies.
5. Added support for macOS 27 and Liquid Glass style, with a richer UI experience.
6. More Adobe Downloader 3.0 features are ready for you to explore."""

    changelog_cn, changelog_en, ps_cn, ps_en = parse_input(txt)
    xml_output = generate_xml(changelog_cn, changelog_en, ps_cn, ps_en)
    print(xml_output)


if __name__ == "__main__":
    main()
