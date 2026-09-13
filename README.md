# Windows 广告过滤实验工具

这是一个针对 Windows 桌面客户端特定版本的个人研究项目，提供简单的双击部署和恢复方式。

## 最简单的用法

1. 下载或克隆仓库。
2. 双击 `Deploy.cmd`。
3. 第一次运行时，在文件选择框中选择目标版本的 DLL；之后脚本会记住本机路径。
4. 需要撤销时双击 `Restore.cmd`。

本机路径只会保存到仓库目录下的 `.local\state.json`，该目录已经被 Git 忽略，不会上传到公开仓库。

### 为什么会弹出选择窗口？

这是为了避免把任何人的安装路径写进仓库。脚本无法安全假定每台电脑的安装盘符和目录，所以首次运行必须手动选择一次文件。

请选择版本目录里的目标 DLL 文件，不要选择 EXE、安装包或其他 DLL。选择成功后，路径会保存在本机 `.local\state.json`，以后再次双击通常不会弹窗。如果每次都弹出，说明上一次部署没有完成，或 `.local` 目录没有写入权限。

### `Restore.cmd` 弹窗时应该选择什么？

正常情况下，部署成功后会自动记录目标 DLL 和原版备份，双击 `Restore.cmd` 不需要选择文件。

如果目标文件已经是本项目确认过的部署状态，但本机缺少备份，`Deploy.cmd` 会先从已验证的字节状态重建一份原版备份，并用完整 SHA-256 再校验一次；无法确认时会停止，不会覆盖文件。

如果本机没有 `.local\state.json`，恢复脚本会按顺序处理：

1. “选择要恢复的目标 DLL”：选择安装目录中当前使用的 DLL。
2. “选择原版备份文件”：选择部署成功时生成的 `target.dll.original`，不要选择当前 DLL，也不要选择 `target.dll.previous`。

原版备份只会在部署成功后生成，通常位于 `.local\backups\original-*`。如果没有这个文件，脚本不会猜测或覆盖未知文件；请先找到备份，或重新安装同一版本后再处理。

## 当前适配范围

- 客户端版本：`4.1.13.65`
- 目标架构：Windows x64
- 其他版本默认拒绝修改，避免把旧偏移误用于新文件。

脚本不依赖 `Get-FileHash`。如果系统 PowerShell 报“无法将 Get-FileHash 项识别为 cmdlet”，请重新下载最新版；当前脚本使用系统自带的 .NET SHA-256 实现，兼容旧版 Windows PowerShell。

当前实验补丁位置：

| 用途 | 文件偏移 | 原始字节 | 修改后字节 |
| --- | ---: | --- | --- |
| 信息流开关 A | `0x5619AEA` | `85 F6 0F 95 C0` | `31 C0 90 90 90` |
| 信息流开关 B | `0x561A41A` | `85 F6 0F 95 C0` | `31 C0 90 90 90` |
| 页面能力候选开关 | `0x3C079DA` | `85 F6 0F 95 C0` | `31 C0 90 90 90` |

第三处是实验性候选点，不保证适用于所有内容，也不保证过滤效果。升级客户端后必须重新分析，不能直接沿用偏移。

## 手动方式

如果不使用双击脚本，可以在 PowerShell 中执行：

```powershell
$dll = Read-Host '请输入目标 DLL 的完整路径'
.\tools\PatchAds.ps1 -Mode Plan -DllPath $dll
.\tools\PatchAds.ps1 -Mode Apply -DllPath $dll
.\tools\PatchAds.ps1 -Mode ExtendPage -DllPath $dll
```

脚本会在修改前自动创建备份。完整恢复需要提供原版备份：

```powershell
.\tools\PatchAds.ps1 -Mode Restore -DllPath $dll -BackupPath '.\backups\apply-YYYYMMDD-HHMMSS\target.dll.original'
```

追加页面补丁也可以单独撤销：

```powershell
.\tools\PatchAds.ps1 -Mode RestorePrevious -DllPath $dll -BackupPath '.\backups\before-page-YYYYMMDD-HHMMSS\target.dll.previous'
```

所有修改和恢复操作都要求目标客户端完全退出。脚本会拒绝未知哈希、未知字节状态和不匹配的备份。

## 构建辅助工具

如需编译 UI Automation 辅助程序：

```powershell
.\tools\Build-Tools.ps1
```

输出位于 `dist`，该目录默认被 Git 忽略。生成的程序用法：

```powershell
.\dist\UiProbe.exe --root '<安装根目录>'
.\dist\UiProbe.exe --root '<安装根目录>' --all
.\dist\AdCleaner.exe --root '<安装根目录>' --apply
.\dist\AdCleaner.exe --root '<安装根目录>' --apply --watch
```

辅助清理器只匹配明确命名的广告关闭按钮，不会调用“不感兴趣”，也不会操作聊天、联系人或消息内容。

## 风险与限制

- 修改 DLL 会使其原有数字签名校验显示为哈希不匹配，这是修改签名文件的必然结果。
- 客户端更新、区域配置、服务端下发策略都可能使补丁失效或导致启动异常。
- 这不是通用广告拦截器，也没有对网络请求做粗粒度屏蔽。
- 使用前请自行备份安装目录，并确认自己有权在本机进行测试。
- 本项目按实验代码发布，不承诺稳定性、兼容性或持续维护。

## 许可证

MIT License，详见 [LICENSE](LICENSE)。
