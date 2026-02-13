# `tune_params.pl` 使用說明（Collect / No-tune / Auto）

本文件以目前程式實作為準（`tune_params.pl`）。

## 1. 三種模式

1. `--collect`
- 只收集 `output/` 下的 `.txt` 資料並輸出 `merged_data.csv`。
- 不執行 `n1.sh`、不調參。

2. `--no-tune`
- 流程：建立 output 子資料夾 -> 初始化 token -> 執行 commands -> collect。
- 不做 BO。
- 輸出：`merged_data.csv`。

3. `--auto`
- 流程：建立 output 子資料夾 -> 初始化 token -> 第一次執行 commands -> collect -> BO -> 套用最佳參數後 rerun -> 第二次 collect -> 寫報表。
- 輸出：`merged_data.csv`、`tuned_params.csv`、`tuning_report.csv`。

## 2. `--auto` 實際步驟（對應 STDERR log）

程式會在 STDERR 印進度（不污染 stdout/CSV）：

1. `Step 1`：`prepare_output_dirs` 開始/結束。
2. `Step 1.5`：token 初始化（`add -> 0`，`mul -> 1`）。
3. `Step 2`：第一次執行 commands（全 dirs）。
4. `Step 3`：第一次 collect（寫 `merged_data.csv`）。
5. `Step 4`：讀 `target.csv` + 建立 join-key 對應。
6. `Step 5`：確定可調參數清單。
7. `Step 6`：建立 BO tasks。
8. `Step 6.1`：BO 任務進度（completed/total）。
9. `Step 6.2`：BO 摘要（converged / likely_bound_limited / missing_result）。
10. `Step 7`：套用最佳參數後 rerun。
11. `Step 8`：第二次 collect。
12. `Step 9`：寫 `tuned_params.csv` 與 `tuning_report.csv`。
13. `Final`：流程完成。

## 3. `n1.sh` 在單一子資料夾最多會跑幾次？

### `--auto`
單一 task（通常對應一個 output 子資料夾）在目前版本的上限為：

- 第一次基準執行：`1` 次（Step 2）
- BO evaluate 總上限：`TR_TOTAL_EVAL_CAP` 次
- 套 best 後 rerun：`1` 次（Step 7）

所以目前（`TR_TOTAL_EVAL_CAP = 24`）：

`最多 = 1 + 24 + 1 = 26 次`

### `--no-tune`
- 通常是 `1` 次（只做一次 commands）。

### `--collect`
- `0` 次（不執行 commands）。

## 4. BO 重要參數（你常問的）

目前關鍵常數：

- `TR_TOTAL_EVAL_CAP = 24`
- `LOCAL_REFINE_EVAL_RESERVE = 13`
- `LOCAL_REFINE_EXTRA_EVAL_CAP = 240`

白話解釋：

1. `TR_TOTAL_EVAL_CAP`
- 每個 task 的**硬上限**評估次數（BO + local refine 合計）。
- 真正決定「最多 evaluate 幾次」的是它。

2. `LOCAL_REFINE_EVAL_RESERVE`
- 預留給 local refine 的配額。
- BO 主階段可用大約是：`TR_TOTAL_EVAL_CAP - LOCAL_REFINE_EVAL_RESERVE`（至少會保留 1）。

3. `LOCAL_REFINE_EXTRA_EVAL_CAP`
- local refine 想額外吃的「意圖上限」。
- 但最後仍會被 `TR_TOTAL_EVAL_CAP` 截斷，所以不是硬上限。

## 5. `--max-rounds` 在目前實作的語意

- `--max-rounds` 是 BO 初始預算（不是最終硬上限）。
- 實際 BO 會自動延伸（`TR_EXTENSION_CHUNK`）直到 BO phase cap。
- 最終 evaluate 仍不可超過 `TR_TOTAL_EVAL_CAP`。

## 6. 收斂與 loss

目前 objective（Hinge-Hybrid）：

`loss = max_abs_error + OBJ_MSE_WEIGHT * mse + OBJ_HINGE_WEIGHT * max(0, max_abs_error - tol)^2`

目前預設：

- `OBJ_MSE_WEIGHT = 0.10`
- `OBJ_HINGE_WEIGHT = 3.0`

收斂條件：

- `max_abs_error < tol`

## 7. `likely_bound_limited` 是什麼？

當 task 沒收斂且評估已打到 cap，而且最佳參數貼近邊界比例達門檻時，會標記：

- `status = likely_bound_limited`

用意：

- 提醒「可能不是演算法壞掉，而是你給的 `min/max` 範圍太窄」。

## 8. Token 初始化（`--no-tune` 與 `--auto`）

兩種模式都會在第一次跑 commands 前做 token 初始化：

- `model=add` -> token 初值 `0`
- `model=mul` -> token 初值 `1`

注意：

- `--auto` 下 `--model` 不影響 BO 搜尋策略本身，只影響這個初始化行為。

## 9. 輸出檔案

1. `output/results/merged_data.csv`
- collect 後彙整資料。

2. `output/results/tuned_params.csv`（auto）
- 每個 task 的最佳參數、`BO_Best_Loss`、`BO_Evals`、`BO_Converged`。

3. `output/results/tuning_report.csv`（auto）
- 各欄位最終值、target、誤差與最佳 loss。

## 10. 收集規則（collect/no-tune/auto 共用）

- 掃描 `output/` 遞迴下的 `.txt`。
- 只處理檔名符合 `@collect_file_keywords`（例如 `all.txt`）。
- 逐行擷取 `key[:=]value` 片段。
- `@collect_data_keys` 若有值就用它；否則用 `%default_param_map` 的 keys。
- 重複 key 會按出現順序編號（如 `D_1`, `D_2`）。
- 程式會輸出 collect 摘要 warning（duplicate/missing/overflow），不會中止流程。

## 11. CLI 對照（嚴格模式）

| Option | 用途 | collect | no-tune | auto |
|---|---|---:|---:|---:|
| `--collect` | collect 模式 | Y | N | N |
| `--no-tune` | no-tune 模式 | N | Y | N |
| `--auto` | auto 模式 | N | N | Y |
| `--data` | merged_data 路徑 | Y | Y | Y |
| `--tuning-file` / `--template` | 模板檔 | N | Y | Y |
| `--target` | 目標 CSV | N | N | Y |
| `--out` | tuned_params 路徑 | N | N | Y |
| `--report` | tuning_report 路徑 | N | N | Y |
| `--params` | 只調指定參數 | N | N | Y |
| `--model` | `add` 或 `mul` | N | Y | Y |
| `--tol` | 收斂容差 | N | N | Y |
| `--step` | 每輪最大變化 | N | N | Y |
| `--min-param` | 全域參數下限 | N | N | Y |
| `--max-param` | 全域參數上限 | N | N | Y |
| `--max-rounds` | BO 初始預算 | N | N | Y |
| `--bo-seed` | BO 隨機種子 | N | N | Y |
| `--join-key` | data/target 對齊欄位 | N | N | Y |
| `--help` | 顯示說明 | Y | Y | Y |

補充：

- 模式衝突或不相干參數會直接報錯。
- 不指定模式也會報錯。

## 12. 建議操作順序

1. 先跑 no-tune 產生基準資料

```bash
perl tune_params.pl --no-tune
```

2. 參考 `output/results/merged_data.csv` 更新 `target.csv`

3. 跑 auto 調參

```bash
perl tune_params.pl --auto
```

4. 若只想重新彙整，不重跑 commands

```bash
perl tune_params.pl --collect
```

## 13. 快速指令

```bash
perl tune_params.pl --help
perl tune_params.pl --collect
perl tune_params.pl --no-tune
perl tune_params.pl --auto
```
