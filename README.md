# `tune_params.pl` 使用說明（Collect / No-tune / Auto）

本文件以目前程式實作為準。

## 三模式定義

1. `--collect`
- 只做資料蒐集。
- 只讀取 `output/` 下遞迴掃描到的 `.txt`。
- 只處理檔名符合 `@collect_file_keywords` 的檔案（例如 `all.txt`）。
- 不執行外部指令、不調參、不回寫模板。
- 輸出：`merged_data.csv`。

2. `--no-tune`
- 固定執行：生成資料夾 -> 執行指令 -> 收集資料。
- 不做調參。
- 輸出：`merged_data.csv`。

3. `--auto`
- 固定執行：生成資料夾 -> 執行指令 -> 收集資料 -> 調參。
- 每輪只重跑參數有變更的資料夾。
- 輸出：`merged_data.csv`、`tuned_params.csv`、`tuning_report.csv`。

## 流程圖（文字版）

- `collect`: scan `output/*.txt` (recursive) -> parse keys -> write `merged_data.csv`
- `no-tune`: prepare output dirs -> run commands -> collect -> write `merged_data.csv`
- `auto`: prepare output dirs -> run commands -> collect -> tune loop -> write 3 CSV files

## 收集規則（collect/no-tune/auto 共用）

- 掃描範圍：`output` 下遞迴所有檔案。
- 檔案類型：只收 `.txt`。
- 檔名過濾：由 `@collect_file_keywords` 決定。
- 行內解析：每一行會用 global 掃描抓出所有 `key[:=]value` 片段。
  - 例如 `cgc=6 D = 5.4` 會解析出 `cgc=6` 與 `D=5.4`，但只收目標 key。
- 關鍵字欄位：
  - 若 `@collect_data_keys` 非空，使用它。
  - 否則使用 `%default_param_map` 的 keys（依目前設定）。
- 非目標 key（例如 `cgc`,`hihi`,`1-sigma`）會直接忽略，不寫入輸出欄位。
- 目標 key 若值非數值（例如 `D=abc`），該欄位留空並繼續流程。
- 若符合檔名關鍵字但內容沒有對應 key，該列保留，值為空字串。
- 若有 `.txt` 檔但沒有任何檔名命中關鍵字，仍會生成 `merged_data.csv`（只有表頭）。
- 若 `output` 不存在，直接報錯。
- 若完全沒有 `.txt`，直接報錯。

## 重複鍵處理（Indexed Keys）

- source format 以 base key 為準（例如 `D=...` 重複多行）。
- 若 `%default_param_map` 只定義 base key（例如 `D`）且 source 有重複 `D`：
  - 會自動編號成 `D_1`,`D_2`,...（依出現順序）。
  - 欄位排序採自然排序（例如 `D_1,D_2,D_3,...`）。
- 若 `%default_param_map` 使用 indexed key（例如 `D_1`,`D_2`）：
  - collector 仍以 base key 行（`D=...`）作為 canonical input。
  - 若 source 檔內同時出現顯式 indexed 行（如 `D_1=...`），會忽略顯式 indexed 行。
- 若定義了 `D_1,D_2` 但檔案只有 1 個 `D`，`D_2` 會留空。
- collector 會輸出摘要 warning（duplicate/missing/overflow 統計），不輸出每檔明細 spam。

## Auto 模式對應規則

- `auto` 模式要求 `%default_param_map` 的 key 必須和收集結果欄位完全對得上。
- 例如 source 有兩個 `D`，收集會得到 `D_1,D_2`；此時若 map 仍是 `D => D1_p`，`auto` 會被阻擋並提示你改成顯式欄位（例如 `D_1 => D1_p, D_2 => D2_p`）。
- 這樣可避免調參時用錯欄位造成不可靠結果。

## Map 索引缺口警告

- 若 `%default_param_map` 有 indexed key 缺口（例如只有 `D_2` 沒有 `D_1`），程式會輸出 warning。
- 這個檢查是 warning-only，不會中止 `collect/no-tune/auto` 流程。

## CLI 對照表（嚴格模式）

| Option | 用途 | collect | no-tune | auto |
|---|---|---:|---:|---:|
| `--collect` | collect 模式 | Y | N | N |
| `--no-tune` | no-tune 模式 | N | Y | N |
| `--auto` | auto 模式 | N | N | Y |
| `--data` | merged_data 路徑 | Y | Y | Y |
| `--tuning-file` / `--template` | 指定模板檔 | N | Y | Y |
| `--target` | 目標 CSV | N | N | Y |
| `--out` | tuned_params 輸出路徑 | N | N | Y |
| `--report` | tuning_report 輸出路徑 | N | N | Y |
| `--params` | 只調指定參數 | N | N | Y |
| `--model` | `add` 或 `mul` | N | N | Y |
| `--tol` | 收斂容差 | N | N | Y |
| `--step` | 每輪最大變化 | N | N | Y |
| `--min-param` | 參數下限 | N | N | Y |
| `--max-param` | 參數上限 | N | N | Y |
| `--max-rounds` | 最大輪數 | N | N | Y |
| `--join-key` | data/target 對齊欄位 | N | N | Y |
| `--help` | 顯示說明 | Y | Y | Y |

說明：
- 嚴格防呆啟用。若模式不相干參數被帶入（例如 `--collect --step 2`），程式會直接報錯。
- 同時指定多個模式（例如 `--collect --auto`）會直接報錯。
- 不指定模式也會直接報錯。

## 已移除選項

- `--full`
- `--no-clean`
- `--emit-merged`
- `--max-iter`

## 常見錯誤對照

1. `Mode required...`
- 沒有指定 `--collect` / `--no-tune` / `--auto`。

2. `Mode conflict...`
- 同時指定了多個模式。

3. `Option '--xxx' is not allowed in --collect mode.`
- 該參數不適用目前模式。

4. `Output folder 'output' not found.`
- collect 模式下找不到 output 目錄。

5. `No .txt files found under 'output'.`
- output 內沒有可收集文字檔。

6. `No matching 'File_Path' between collected data and 'target.csv'.`
- auto 模式下，收集資料與 target 完全對不到。

7. `[WARN] collect summary: ...`
- 表示收集過程偵測到重複 base key、缺少 indexed key、或 overflow 擴欄。

8. `[WARN] incomplete indexed keys in %default_param_map: ...`
- 表示 map 有索引缺口（例如缺 `D_1`），目前是警告不中止。

## 建議操作順序

1. 先執行 `no-tune` 產生基準資料：
```bash
perl tune_params.pl --no-tune
```

2. 以 `output/results/merged_data.csv` 為基礎手動更新 `target.csv`。

3. 執行 auto 調參：
```bash
perl tune_params.pl --auto
```

4. 若只想檢查目前 output 內資料，不重跑任何指令：
```bash
perl tune_params.pl --collect
```

## 快速指令

```bash
perl tune_params.pl --help
perl tune_params.pl --collect
perl tune_params.pl --no-tune
perl tune_params.pl --auto
```
