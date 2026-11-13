#!/usr/bin/env swift
//
// AX 诊断脚本：检查 Teams/Zoom 的 Accessibility 树
// 用法：swift ax-diagnose.swift
//

import AppKit
import ApplicationServices

let targetBundleIDs: Set<String> = [
    "com.microsoft.teams",
    "com.microsoft.teams2",
    "us.zoom.xos",
]

// 1. 检查权限
print("=== AX 权限检查 ===")
print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
if !AXIsProcessTrusted() {
    print("❌ 辅助功能权限未授予！请在「系统设置 → 隐私与安全性 → 辅助功能」中添加终端。")
    exit(1)
}
print("✅ 权限已授予")

// 2. 查找运行中的会议应用
print("\n=== 查找会议应用 ===")
let runningApps = NSWorkspace.shared.runningApplications.filter { app in
    guard let bid = app.bundleIdentifier else { return false }
    return targetBundleIDs.contains(bid)
}

if runningApps.isEmpty {
    print("❌ 没有找到运行中的 Teams/Zoom")
    print("   当前运行的应用 Bundle IDs:")
    for app in NSWorkspace.shared.runningApplications {
        if let bid = app.bundleIdentifier {
            print("     - \(bid) (PID: \(app.processIdentifier))")
        }
    }
    exit(1)
}

for app in runningApps {
    print("✅ 找到: \(app.bundleIdentifier!) (PID: \(app.processIdentifier))")
}

// 3. 对每个应用遍历 AX 树
for app in runningApps {
    let pid = app.processIdentifier
    let bundleID = app.bundleIdentifier!
    print("\n=== 分析 \(bundleID) (PID: \(pid)) ===")

    let appElement = AXUIElementCreateApplication(pid)

    // 尝试开启 Electron AX
    var enableFlag: UInt8 = 1
    let enableValue = CFNumberCreate(kCFAllocatorDefault, .sInt8Type, &enableFlag)
    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, enableValue as CFTypeRef)
    print("已设置 AXManualAccessibility")

    // 获取窗口
    var windowsRef: CFTypeRef?
    let windowsResult = AXUIElementCopyAttributeValue(
        appElement, kAXWindowsAttribute as CFString, &windowsRef
    )

    print("获取窗口结果: \(windowsResult.rawValue)")
    if windowsResult != .success {
        print("❌ 无法获取窗口列表，错误码: \(windowsResult.rawValue)")
        continue
    }

    guard let windows = windowsRef as? [AXUIElement] else {
        print("❌ 窗口列表转换失败")
        continue
    }

    print("窗口数量: \(windows.count)")

    for (winIndex, window) in windows.enumerated() {
        // 获取窗口标题
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let winTitle = (titleRef as? String) ?? "(无标题)"
        print("\n--- 窗口[\(winIndex)]: \(winTitle) ---")

        // 搜索包含 mute 相关关键词的元素
        var foundCount = 0
        searchMuteElements(in: window, depth: 0, maxDepth: 12, windowLabel: "窗口[\(winIndex)]", foundCount: &foundCount)

        if foundCount == 0 {
            print("  （该窗口未找到 mute 相关元素）")
        }
    }
}

// MARK: - 递归搜索

func searchMuteElements(in element: AXUIElement, depth: Int, maxDepth: Int, windowLabel: String, foundCount: inout Int) {
    guard depth <= maxDepth else { return }

    // 获取 Role
    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    let role = (roleRef as? String) ?? "(无)"

    // 获取多种属性
    let attributes: [String] = [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXHelpAttribute as String,
        kAXValueAttribute as String,
        kAXLabelValueAttribute as String,
    ]

    var allDescriptions: [String] = []
    for attr in attributes {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &valueRef)
        if result == .success {
            if let str = valueRef as? String, !str.isEmpty {
                allDescriptions.append("\(attr)=\"\(str)\"")
            }
        }
    }

    let combined = allDescriptions.joined(separator: " ").lowercased()

    // 检查是否包含 mute 相关关键词
    let muteKeywords = ["mute", "unmute", "静音", "取消静音", "microphone", "mic", "麦克风", "话筒"]
    let isMuteRelated = muteKeywords.contains { combined.contains($0) }

    if isMuteRelated {
        foundCount += 1
        let indent = String(repeating: "  ", count: depth + 1)
        print("\(indent)🔔 [depth=\(depth)] role=\(role)")
        for desc in allDescriptions {
            print("\(indent)   \(desc)")
        }
    }

    // 递归子元素
    var childrenRef: CFTypeRef?
    let childrenResult = AXUIElementCopyAttributeValue(
        element, kAXChildrenAttribute as CFString, &childrenRef
    )

    guard childrenResult == .success,
          let children = childrenRef as? [AXUIElement] else {
        return
    }

    for child in children {
        searchMuteElements(in: child, depth: depth + 1, maxDepth: maxDepth, windowLabel: windowLabel, foundCount: &foundCount)
    }
}

print("\n=== 诊断完成 ===")
