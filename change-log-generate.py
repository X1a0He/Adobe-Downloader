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
    txt = """1. 修复了清理工具执行清理时出现清理不全面的问题
2. 新增修复 Helper 的 sh 脚本和入口
3. 默认选中 SuperCafModels 包
4. 升级 Sparkle 到 2.8.1

====================

1. Fixed an issue where the cleanup tool would not clean up all files.
2. Added a sh script and entry for repairing Helper.
3. Selected SuperCafModels package by default.
4. Upgraded Sparkle to 2.8.1."""

    changelog_cn, changelog_en, ps_cn, ps_en = parse_input(txt)
    xml_output = generate_xml(changelog_cn, changelog_en, ps_cn, ps_en)
    print(xml_output)


if __name__ == "__main__":
    main()
