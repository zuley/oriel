# 05A Curious 暖色方案历史验收 · 2026-11-09

此方案已按用户“中性底色、主色仅作点缀”的修订替换。当前规则见 [DESIGN.md](../../../DESIGN.md)，当前截图见 [中性配色验收](../palette-neutral/README.md)。

用户在选定 05A 后要求「应用整体的配色，也基于这个调整」。颜色统一收于 [OrielPalette.swift](../../../OrielApp/OrielPalette.swift)，规则见 [DESIGN.md](../../../DESIGN.md)。本轮延伸桃色表面、珊瑚色操作与暖黄选中提示，沿用原生 Aqua、既有布局和行为。

## 实机证据

全部为实际 AppKit / SwiftUI 窗口截图；管理窗口截图为 860×652 px（含标题栏），迷你窗采用默认背景与内容不透明度 0.75。

| 范围 | 截图 |
| --- | --- |
| 主界面 | [空工作台](workspace-empty.png)、[工作台](workspace.png)、[设置](settings.png) |
| 迷你窗 | [首页](home.png)、[活动页签](tabs.png)、[便签](notes.png)、[书架](books.png) |
| 内容 | [行情](stocks.png)、[终端](terminal.png)、[浏览器](browser.png) |

浏览器图为最终 CSS 生效后的应用自有起始页；另在实际 WKWebView 中查看了简短内部 HTML。外部网站不改色。行情红绿、蜡烛图与系统交通灯保留语义。

## 验证结果

- [构建日志](../../../.build/palette-build.log)：`./scripts/build.sh` 通过；[测试日志](../../../.build/palette-tests.log)：47 项通过、0 失败。严格代码签名校验与 diff 空白检查通过；应用已重新启动至最终构建。
- [contrast.json](contrast.json) 记录 9 组完全不透明颜色的计算值：正文/画布 12.27、辅助文字/画布 5.65、辅助文字/侧栏 5.23、accent/导航选中底色 4.66、白字/accent 5.76、accent/活动页签 5.07、amber/活动页签 4.66、边界/表面 3.57、终端默认文字/底色 14.7。前述文字组合达到 4.5:1，边界组合达到 3:1。
- 独立审阅结论为文档同步后可交付，无实现必修项。QA 创建的小窗已关闭，最终应用停留在主工作台。

## 边界

最小尺寸拖动截图未取得（CUA 返回 `noWindowsAvailable`）；透明度浮层捕获失败，误标图片已移除。滑轨颜色已核对源码，未获得该浮层的实机视觉验收。

这些记录不证明任意用户透明度下的对比度、深色界面、行情语义文字的 AA、所有空/错状态或完整后端功能。原生界面未运行网页检测器；不把内部 WKWebView 检查扩展为整站验收。菜单栏真实明暗外观切换仍未验证。
