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
    txt = """- fix: 修复了在下载 Adobe 产品的过程中，出现内存占用过大的问题
- fix: 修复了在部分 Adobe 产品安装过程中，出现错误的问题
- fix: 修复了在部分 Adobe 产品安装完成后，因权限而无法启动 App 的问题
- feat: 优化了安装 Sheet 的显示，避免在屏幕太小的时候无法点击到最底部的按钮
- feat: 为取消安装增加回滚
- feat: 同步 Adobe Creative Cloud 官方安装行为，在安装后添加卸载快捷方式
- feat: 引入了增量更新功能，在 3.1.0 版本中可以实现对已有产品的增量更新(必需使用 Adobe Downloader 下载)
- feat: 优化了部分产品的版本选择页面

====================

- fix: Fixed excessive memory usage during Adobe product downloads
- fix: Fixed errors that occurred during installation of some Adobe products
- fix: Fixed issue where some Adobe products could not launch due to permission problems after installation
- feat: Optimized the installation Sheet display to prevent bottom buttons from being unreachable on small screens
- feat: Added rollback support for installation cancellation
- feat: Synced with Adobe Creative Cloud official installation behavior, adding uninstall shortcuts after installation
- feat: Introduced incremental update functionality — in version 3.1.0, you can perform incremental updates on already installed products (must be downloaded using Adobe Downloader)
- feat: Optimized the version selection page for some products"""

    changelog_cn, changelog_en, ps_cn, ps_en = parse_input(txt)
    xml_output = generate_xml(changelog_cn, changelog_en, ps_cn, ps_en)
    print(xml_output)


if __name__ == "__main__":
    main()
