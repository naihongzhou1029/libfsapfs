# 開發日誌索引 / Development Journal Index

# 2026/07/17

## 修好 Windows raw device 讀取,實測掛載外接 APFS 磁碟

今天測試前幾天 build 出來的 `fsapfsmount.exe` 能不能真的把一顆 1 TB 的 APFS 格式外接 USB SSD(Micron CT1000X8SSD9,512-byte 扇區,GPT 分割,APFS container 在 Partition 2 offset `135266304`)掛載成 Windows 磁碟機。結果一路踩到 `libcfile` 的一個潛藏已久的錯誤,追到底之後把修法固定進自己的 fork。

### 症狀

- 以系統管理員權限跑 `.\build\Release\x64\fsapfsinfo.exe -o 135266304 \\.\PhysicalDrive1`,直接失敗:「Unable to open」加上一整串 `libcfile_internal_file_read_buffer_at_offset_with_error_code: unable to read from file with error: The parameter is incorrect.」的 stack trace。
- 換成 `\\.\Harddisk1Partition2` 、 `\\?\Harddisk1Partition2`,同樣失敗,但失敗點不同 —— 前者是 read 階段爆,後者連 open(取 file size)就爆。
- 用 PowerShell / .NET 的 `[System.IO.File]::OpenRead('\\.\PhysicalDrive1')` 手動讀 4096 bytes @ offset `135266304`,一次就抓到 APFS `nx_superblock_t` 的開頭 `1E-8B-3F-B4-F7-8F-36-40 01-00-00-00-00-00-00-00`(前 8 bytes 是 Fletcher-64 checksum,接的 `01-00-...` 正好是 container superblock 固定 OID `= 1`)。
- 也就是說,磁碟通道與權限都沒問題,bug 在 `libcfile` 的 Windows raw device I/O 實作。

### 診斷:加暫時 debug print 抓出真正的參數

在 `libcfile_internal_file_read_buffer_at_offset_with_error_code()` 加了幾行 `fprintf(stderr, ...)`,印出 async 旗標、offset、size、block_size、file_size,再跑一次。結果:

```
[DBG] read_at_offset: async=0 offset=135266304 size=4095 block_size=3 file_size=1000204886016 current=135266304
[DBG] ReadFile returned result=0 read_count=0 overlapped=... err=87
```

兩個明顯的線索:

- `block_size = 3` —— 不合理的扇區大小
- `size = 4095` —— libfsapfs 明明要求 4096 bytes,實際下的 read 卻只有 4095;不是 512 的倍數,Windows raw device I/O 直接回 ERROR_INVALID_PARAMETER 87

追進 `libcfile_internal_file_determine_block_size()`,發現 Vista+ 的分支呼叫 `GetFileInformationByHandleEx(FileAlignmentInfo)`,再把 `AlignmentRequirement` 直接當 bytes-per-sector 用:

```c
bytes_per_sector = (size_t) file_alignment_information.AlignmentRequirement;
```

這是天大的誤解。 `AlignmentRequirement` 是 Windows 定義的 `FILE_*_ALIGNMENT` 列舉值,語意是「若要用 `FILE_FLAG_NO_BUFFERING` 開檔,buffer 記憶體地址必須對齊多少 bytes」,而且回傳的值本身就是「對齊 N+1 bytes」的編碼 —— `FILE_LONG_ALIGNMENT = 3` 代表「對齊到 4 bytes」,不是「3 bytes per sector」。這個外接 USB SSD 回 `3`,於是 `block_size = 3`,接著 read 邏輯執行 `read_size = 4096 - (4096 % 3) = 4095`,把非扇區倍數的長度丟給 raw device,Windows 一律拒絕。

而且我們根本沒用 `FILE_FLAG_NO_BUFFERING`,`AlignmentRequirement` 對我們毫無意義。

### 修法

`libcfile_internal_file_determine_block_size()` 的 pre-Vista 分支本來就有正確做法:呼叫 `IOCTL_DISK_GET_DRIVE_GEOMETRY_EX` 拿到真正的 `Geometry.BytesPerSector` 。這個 IOCTL 從 Windows 2000 就存在,沒必要區分 Vista 前後。所以直接把 Vista+ 那整段 `FILE_ALIGNMENT_INFO` 拿掉、統一走 IOCTL 路徑;`response_count` 變數的 `WINVER < 0x0600` 條件也一併移除。

改完再跑一次 debug 版:每個 read `block_size = 512` 、 `size` 都是扇區倍數(4096 或 512),`ReadFile` 全部成功。拿掉 debug print 重編,`fsapfsinfo` 秒讀出來:

```
Container information:
    Identifier      : 5f680d92-4877-4f8a-97b7-b1a562568496
    Number of volumes   : 1

Volume: 1 information:
    Identifier      : 05138196-b828-4346-9581-650867c9f0b8
    Name            : Project
    Incompatible features   : 0x00000001 (APFS_INCOMPAT_CASE_INSENSITIVE)
```

`fsapfsmount -o 135266304 \\.\PhysicalDrive1 X:` 也成功透過 Dokan 把 volume 掛成 `X:`,`Get-ChildItem X:\` 列得出所有 macOS 特徵目錄(`.Spotlight-V100` 、 `.fseventsd` 、 `.DocumentRevisions-V100` 、 `.Trashes` 、 `.DS_Store`)與使用者資料。讀 `.DS_Store`(18436 bytes)也 OK。

實驗性地把「device open 時強制 `use_asynchronous_io = 0` 」那個備用修法 revert 掉,只留 block_size 修法,結果一樣成功 —— 確認 async I/O 本身沒問題,真正的 bug 只有 `FILE_ALIGNMENT_INFO` 誤用一個。

### 持久化:fork `libyal/libcfile` 到自己的 GitHub

`libcfile/` 是 `.gitignore` 排除的,由 `synclibs.ps1` 從 `libyal/libcfile` clone 進來,直接改本機檔案下次 sync 會被蓋掉。原本考慮走「patch 檔 + sync 後自動套用」的路,但既然是自己會長期維護的東西,直接 fork 更乾淨。

- Fork 到 `https://github.com/naihongzhou1029/libcfile.git`,把修過的 `libcfile_file.c` push 到 fork 的 `main`(commit `882e45c`,含完整 root cause 說明)。
- `synclibs.ps1` 加 `$GitUrlOverrides` hashtable,libcfile 的 URL 覆寫成 fork,其餘 libyal libs 維持原本 upstream。
- 跑一次 `synclibs.ps1` 驗證整條路徑:log 顯示 `Synchronizing: libcfile from https://github.com/naihongzhou1029/libcfile.git HEAD`,sync 完的 `libcfile/libcfile_file.c` 與 sync 前的備份 byte-for-byte 一致,修法完整保留。

### 待辦

- 這個 bug 是通用的 `libcfile` 缺陷,只要在 Windows 上讀 raw device 都會踩到。等有空時把 commit `882e45c` 整理成 pull request 送回 `libyal/libcfile` upstream,若被合併就能把 fork override 從 `synclibs.ps1` 拿掉。
- 現在 fork 的 sync 走 HEAD(因為 fork 沒複製 upstream 的 tag),若之後 upstream 出新 tag 想跟上,需要在 fork 補 tag、或改 `synclibs.ps1` 的 tag 偵測邏輯,這裡先放著。

# 2026/07/09

## AGENTS.md 專案指引

- 調查 Windows 建置方式：專案內建 `msvscpp/libfsapfs.sln` （Visual Studio 2008 格式），包含 `fsapfsinfo` 、 `fsapfsmount` 、 `libfsapfs` 、 `pyfsapfs` 、60+ 測試專案及 `zlib` 相依。開啟後 VS 會觸發一次性升級。僅有 Win32 平台組態，無 x64。FUSE 掛載工具在 Windows 上需要額外搭配 WinFUSE/Dokany。
- 探索 libfsapfs 專案結構（autotools C 函式庫、Python 繫結、CLI 工具），讀取 `configure.ac` 、 `Makefile.am` 、 `README` 、 `tox.ini` 、測試基礎設施等關鍵原始檔。
- 建立 `AGENTS.md` ，涵蓋建構系統、儲存庫結構、測試方式（C Autotest + Python）、Python 打包流程、常見任務表格、平台注意事項及注意事項。
- 提交並推送 `AGENTS.md` 至 `main` （commit `0e8137d` ）。

## Dokan 核心驅動程式的下載與安裝

`devops.ps1` 的 `env` 指令目前只會同步、建置 `dokany` 的使用者態元件(`dokan1.lib` 、 `dokan1.dll`),並不會安裝 Dokan 的核心驅動程式(kernel driver)——這一步刻意不自動化,補充說明如下。

- 驅動程式的二進位安裝檔不會透過 `syncdokan.ps1` 一起下載下來,該腳本只 `git clone` `dokany` 的原始碼(標頭檔、 `.lib`/`.dll`),必須另外從官方 Release 頁面取得:`https://github.com/dokan-dev/dokany/releases` 。
- 因為 `syncdokan.ps1` 已釘住 `dokany` 版本為 tag `v1.5.1.1000`(理由詳見上方 dokan/fsapfsmount 支援段落,為了跟 `msvscpp_convert.py --with-dokany` 寫死的 `dokan1.lib` 命名相容),下載安裝檔時也要挑同一個 tag 對應的版本(例如 `Dokan_x64.msi` 這類 Asset),確保核心驅動與連結進 `fsapfsmount.exe` 的 `dokan1.dll` 版本一致。
- 安裝步驟：下載 x64 版 `.msi` 安裝檔,以系統管理員權限執行(會安裝核心驅動,可能需要重新啟動或重新載入驅動),完成後 `build\Release\x64\fsapfsmount.exe`(已建置成功)才能真正掛載磁碟。
- `devops.ps1` 不自動處理這一步的原因：核心驅動安裝屬於系統層級操作,需要管理員權限、有時還需要重新啟動,已超出建置腳本自動化的合理範圍。這是刻意保留的固定限制,不是待辦事項。

## 建立 `devops.ps1`,整合 Windows 開發流程並修好 dokan 掛載支援

今天從零設計了 `devops.ps1`,把原本分散在一堆獨立腳本(`autogen.ps1` 、 `build.ps1` 、 `synclibs.ps1` 、 `synczlib.ps1` 、 `syncdokan.ps1` 、 `builddokan.ps1` 、 `runtests.ps1`)裡的 Windows 開發流程,整併成單一入口的四個指令:

- `env` ：檢查/安裝建置所需的工具鏈(`git` 、 `python` 、 `MSBuild`/VS C++ 工作負載),並同步建置相依項(本地函式庫、 `zlib` 、 `dokan`)。
- `build` ：把最終產物建置到 `build\<Configuration>\<Platform>\` 。
- `clean` ：清除 `build\` 底下的產物(保留 `build\vstools`)。
- `rebuild` ： `clean` 後再 `build` 。

過程中發現並修掉了幾個既有的坑：

- `build.ps1` 原本結尾一律 `Exit 0`,完全不管 `MSBuild` 是否真的失敗,導致 CI 長期以來可能都在假綠燈。改成依照真實結束碼回報,只有失敗時才印出完整記錄。
- 新增 `-OutDir` 、 `-MSBuildPath` 參數給 `build.ps1`,讓 `devops.ps1` 可以把產物導到 `build\`,並指定「真正裝了 C++ 工作負載」的那個 `MSBuild`(這台機器上有兩個 VS 安裝,`PATH` 裡的那個沒裝 C++ 工作負載)。
- `vstools` 改放到 `build\vstools`;但 `zlib` 、本地相依函式庫(`libbfio` 、 `libcerror` 等)因為 `msvscpp\*.vcproj` 裡寫死了相對路徑,只能維持原位置。

### `dokan`/`fsapfsmount` 支援

使用者要求把 `dokan` 也納入 `env`,讓 `fsapfsmount.exe`(APFS 掛載工具)能一起建置成功。過程中踩到幾個版本相容性的坑：

- 改用主動維護的 `dokany`(取代 checked-in 專案檔預設寫死的舊版 `dokan 0.6.0`,後者只支援 `Win32`)。
- `dokany` 最新版（ `v2.x` ）產生的檔名是 `dokan2.lib` ，但 `libyal` 的 `msvscpp_convert.py --with-dokany` 轉換邏輯是照舊的 `v1.x` 命名寫死抓 `dokan1.lib` 。解法：把 `syncdokan.ps1` 同步 `dokany` 時釘住最後一個相容版本 `v1.5.1.1000` （沿用這個專案本來就有的「釘死特定舊版相依」慣例， `synczlib.ps1` 也是這樣處理 `zlib` ）。
- `dokany` 專案檔寫死的 Windows SDK 版本（ `10.0.19041.0` ）和 `PlatformToolset` （ `v141` ）這台機器都沒裝，於是給 `builddokan.ps1` 加上 `-WindowsSdkVersion` （自動偵測已安裝版本）和 `-PlatformToolset` （由 `devops.ps1` 依 `VisualStudioVersion` 算出對應值，如 2022 → `v143` ）覆寫參數。
- `build` 成功後自動把 `dokan1.dll` 複製進輸出目錄，因為 `fsapfsmount.exe` 是動態連結它，沒有這個 `.dll` 會連啟動都不行。

### 驗證結果

實測跑完整輪 `env` → `build` → `clean` → `rebuild` ， `build\Release\x64\` 底下正確產出： `libfsapfs.dll` 、 `fsapfsinfo.exe` 、 `fsapfsmount.exe` 、 `pyfsapfs.pyd` 、 `dokan1.dll` ，結束碼均為 `0` 。

已知限制：要讓 `fsapfsmount.exe` 真正「掛載」磁碟，使用者機器上還需要另外安裝 `Dokan` 的核心驅動程式（需要系統管理員權限）， `devops.ps1` 目前不會、也不打算自動處理這個系統層級的驅動安裝。
