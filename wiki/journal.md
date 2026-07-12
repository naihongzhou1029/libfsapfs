# 開發日誌索引 / Development Journal Index

# 2026/07/09

## AGENTS.md 專案指引

- 調查 Windows 建置方式：專案內建 `msvscpp/libfsapfs.sln`（Visual Studio 2008 格式），包含 `fsapfsinfo`、`fsapfsmount`、`libfsapfs`、`pyfsapfs`、60+ 測試專案及 `zlib` 相依。開啟後 VS 會觸發一次性升級。僅有 Win32 平台組態，無 x64。FUSE 掛載工具在 Windows 上需要額外搭配 WinFUSE/Dokany。
- 探索 libfsapfs 專案結構（autotools C 函式庫、Python 繫結、CLI 工具），讀取 `configure.ac`、`Makefile.am`、`README`、`tox.ini`、測試基礎設施等關鍵原始檔。
- 建立 `AGENTS.md`，涵蓋建構系統、儲存庫結構、測試方式（C Autotest + Python）、Python 打包流程、常見任務表格、平台注意事項及注意事項。
- 提交並推送 `AGENTS.md` 至 `main`（commit `0e8137d`）。

## Dokan 核心驅動程式的下載與安裝

`devops.ps1` 的 `env` 指令目前只會同步、建置 `dokany` 的使用者態元件(`dokan1.lib`、`dokan1.dll`),並不會安裝 Dokan 的核心驅動程式(kernel driver)——這一步刻意不自動化,補充說明如下。

- 驅動程式的二進位安裝檔不會透過 `syncdokan.ps1` 一起下載下來,該腳本只 `git clone` `dokany` 的原始碼(標頭檔、`.lib`/`.dll`),必須另外從官方 Release 頁面取得:`https://github.com/dokan-dev/dokany/releases`。
- 因為 `syncdokan.ps1` 已釘住 `dokany` 版本為 tag `v1.5.1.1000`(理由詳見上方 dokan/fsapfsmount 支援段落,為了跟 `msvscpp_convert.py --with-dokany` 寫死的 `dokan1.lib` 命名相容),下載安裝檔時也要挑同一個 tag 對應的版本(例如 `Dokan_x64.msi` 這類 Asset),確保核心驅動與連結進 `fsapfsmount.exe` 的 `dokan1.dll` 版本一致。
- 安裝步驟：下載 x64 版 `.msi` 安裝檔,以系統管理員權限執行(會安裝核心驅動,可能需要重新啟動或重新載入驅動),完成後 `build\Release\x64\fsapfsmount.exe`(已建置成功)才能真正掛載磁碟。
- `devops.ps1` 不自動處理這一步的原因：核心驅動安裝屬於系統層級操作,需要管理員權限、有時還需要重新啟動,已超出建置腳本自動化的合理範圍。這是刻意保留的固定限制,不是待辦事項。

## 建立 `devops.ps1`,整合 Windows 開發流程並修好 dokan 掛載支援

今天從零設計了 `devops.ps1`,把原本分散在一堆獨立腳本(`autogen.ps1`、`build.ps1`、`synclibs.ps1`、`synczlib.ps1`、`syncdokan.ps1`、`builddokan.ps1`、`runtests.ps1`)裡的 Windows 開發流程,整併成單一入口的四個指令:

- `env`：檢查/安裝建置所需的工具鏈(`git`、`python`、`MSBuild`/VS C++ 工作負載),並同步建置相依項(本地函式庫、`zlib`、`dokan`)。
- `build`：把最終產物建置到 `build\<Configuration>\<Platform>\`。
- `clean`：清除 `build\` 底下的產物(保留 `build\vstools`)。
- `rebuild`：`clean` 後再 `build`。

過程中發現並修掉了幾個既有的坑：

- `build.ps1` 原本結尾一律 `Exit 0`,完全不管 `MSBuild` 是否真的失敗,導致 CI 長期以來可能都在假綠燈。改成依照真實結束碼回報,只有失敗時才印出完整記錄。
- 新增 `-OutDir`、`-MSBuildPath` 參數給 `build.ps1`,讓 `devops.ps1` 可以把產物導到 `build\`,並指定「真正裝了 C++ 工作負載」的那個 `MSBuild`(這台機器上有兩個 VS 安裝,`PATH` 裡的那個沒裝 C++ 工作負載)。
- `vstools` 改放到 `build\vstools`;但 `zlib`、本地相依函式庫(`libbfio`、`libcerror` 等)因為 `msvscpp\*.vcproj` 裡寫死了相對路徑,只能維持原位置。

### `dokan`/`fsapfsmount` 支援

使用者要求把 `dokan` 也納入 `env`,讓 `fsapfsmount.exe`(APFS 掛載工具)能一起建置成功。過程中踩到幾個版本相容性的坑：

- 改用主動維護的 `dokany`(取代 checked-in 專案檔預設寫死的舊版 `dokan 0.6.0`,後者只支援 `Win32`)。
- `dokany` 最新版（`v2.x`）產生的檔名是 `dokan2.lib`，但 `libyal` 的 `msvscpp_convert.py --with-dokany` 轉換邏輯是照舊的 `v1.x` 命名寫死抓 `dokan1.lib`。解法：把 `syncdokan.ps1` 同步 `dokany` 時釘住最後一個相容版本 `v1.5.1.1000`（沿用這個專案本來就有的「釘死特定舊版相依」慣例，`synczlib.ps1` 也是這樣處理 `zlib`）。
- `dokany` 專案檔寫死的 Windows SDK 版本（`10.0.19041.0`）和 `PlatformToolset`（`v141`）這台機器都沒裝，於是給 `builddokan.ps1` 加上 `-WindowsSdkVersion`（自動偵測已安裝版本）和 `-PlatformToolset`（由 `devops.ps1` 依 `VisualStudioVersion` 算出對應值，如 2022 → `v143`）覆寫參數。
- `build` 成功後自動把 `dokan1.dll` 複製進輸出目錄，因為 `fsapfsmount.exe` 是動態連結它，沒有這個 `.dll` 會連啟動都不行。

### 驗證結果

實測跑完整輪 `env` → `build` → `clean` → `rebuild`，`build\Release\x64\` 底下正確產出：`libfsapfs.dll`、`fsapfsinfo.exe`、`fsapfsmount.exe`、`pyfsapfs.pyd`、`dokan1.dll`，結束碼均為 `0`。

已知限制：要讓 `fsapfsmount.exe` 真正「掛載」磁碟，使用者機器上還需要另外安裝 `Dokan` 的核心驅動程式（需要系統管理員權限），`devops.ps1` 目前不會、也不打算自動處理這個系統層級的驅動安裝。
