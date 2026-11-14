# Oriel
<!-- impeccable:product-schema 1 -->

## Platform
Native macOS (AppKit and SwiftUI), macOS 14 and later.

## Product Purpose
让终端、阅读、行情、便签在一个可移动、可缩放的小窗中随手可用。主界面仅提供小窗管理与全局设置，不展示或管理业务内容。

## Operating Context
本地菜单栏常驻应用；关闭管理窗口不退出应用。多个独立小窗、每窗多页签；小窗支持穿透、边缘唤醒、独立背景与内容透明度。用户要求每次完成修改后构建并重启以便体验。

## Capabilities and Constraints
便签与书架保存在本机；小说只导入本地 TXT 或 EPUB，行情使用腾讯财经。没有账号、云同步或发布要求。沉浸模式已按用户要求移除。主界面的实现细节由用户授权自行规划。

## Product Principles
- 操作紧凑、文案简短。
- 主界面管理窗口，小窗负责内容与页签。
- 数据保存失败必须可见，不能丢弃未保存文字。
- 验证构建、自动化测试与实机行为，分别记录。
