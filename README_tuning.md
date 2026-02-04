# 自動調參腳本說明（繁體中文版）

這份文件說明 `tune_params.pl` 的完整流程、使用方式、可調設定、資料收集規則與調參演算法。內容以目前程式實作為準。

**適用情境**
- 你有一組基準檔案，需要依照參數變動產生多組 output 子資料夾
- 你希望自動跑指令、收集結果並調整參數，使輸出接近 `target.csv`
- 你不想手動改檔案，想把「建立 output、執行、收集、調參」整合成一個入口

---

**快速開始**
1. 一般全流程（含調參）
```
perl tune_params.pl --auto --full
```
2. 不調參（只建 output + 跑指令 + 收集資料）
```
perl tune_params.pl --no-tune --full
```
3. 收集 + 單次計算（不重建 output、不重跑指令，需已有 output）
```
perl tune_params.pl --collect
```

---

**完整流程說明**
1. 產生 output 子資料夾（`--full`）
- 依 `@modifications` 做笛卡爾拆分，產生多個子資料夾
- 把 `@modifications` 內列出的檔案複製到每個子資料夾
- 自動補上 `param_tuning_file`，避免漏複製

2. 執行每個子資料夾指令
- 依 `@run_commands` 逐一在子資料夾內執行
- 通常會產生輸出檔（例如 `all.txt`）

3. 收集資料
- 依 `@collect_file_keywords` 決定要收哪些檔案
- 依 `@collect_data_keys` 決定要收哪些 key
- 產生 `merged_data.csv`（若有 `--emit-merged`、`--no-tune` 或 `--collect`）

4. 調參（`--auto`）
- 讀取 `target.csv`
- 依 `%default_param_map` 建立「輸出欄位 -> 參數」對應
- 依 `@select_params` 或 `--params` 限縮要調的參數
- 根據現有輸出與 target 計算參數更新量
- 覆蓋 output 子資料夾內的 `param_tuning_file`
- 重跑指令、再次收集，直到收斂或達 `max_rounds`

---

**不調參模式（--no-tune）**
- 只做「建立 output -> 執行指令 -> 收集資料」
- 不計算參數、不產生 tuned_params / tuning_report
- 會自動輸出 `merged_data.csv`
- 會自動啟用 `--full`

---

**收集模式（--collect）**
- 只做「收集資料 + 單次計算參數」
- 不會重建 output，也不會重新執行 @run_commands
- 需已有 output 子資料夾與可收集的輸出檔案
- 會輸出 `merged_data.csv`、`tuned_params.csv`、`tuning_report.csv`
- 會覆蓋 output 子資料夾內的 `param_tuning_file`

---

**參數對應規則（%default_param_map）**
- 本程式不再使用 `param_list.csv`
- 參數對應全由 `%default_param_map` 決定
- 只有 `%default_param_map` 內的欄位會被調參
- 沒有在 map 內的欄位會被忽略

範例：
```
my %default_param_map = (
    cgc => 'cgc_p',
    vth => 'vth_p',
    ids => 'ids_p',
);
```

---

**參數篩選（@select_params / --params）**
- `@select_params` 可指定只調某些參數
- CLI 也可用 `--params cgc_p,ids_p`
- 若篩選結果為空，程式會停止並提示錯誤

---

**資料收集規則**
1. 收集檔案
- `@collect_file_keywords` 為檔名關鍵字
- 檔名包含任一關鍵字才會被收集
- 若清空 `@collect_file_keywords`，會收集所有檔案

2. 收集數據
- `@collect_data_keys` 為要收集的 key 名稱
- 若清空，會自動使用 `%default_param_map` 的 key
- 只接受 `key: value` 或 `key = value` 形式的輸出行

3. 產生欄位
- `File_Path` 為絕對路徑
- `File_Name` 為檔名
- 其餘欄位為收集到的 key

注意：`target.csv` 的 `File_Path` 必須能對上收集的檔案路徑，否則會警告並跳過

---

**輸出檔案**
- `output/results/merged_data.csv`
  - 只有 `--emit-merged`、`--no-tune` 或 `--collect` 時才會輸出
- `output/results/tuned_params.csv`
  - 每個路徑對應的最終參數值
- `output/results/tuning_report.csv`
  - 欄位為 `xxx_final_adjusted / xxx_target / xxx_final_error`
  - `final_adjusted` 是最後一次收集到的數值

---

**調參算法說明（與程式一致）**
- `model = add`
  - 每輪計算 `delta = target - data`
  - 用平均 delta 更新參數
  - 會用 `step` 夾住每輪變化量
- `model = mul`
  - 每輪計算 `ratio = target / data`
  - 用幾何平均 ratio 更新參數
  - 會用 `step` 夾住倍率變化

在 `--auto` 模式中，每一輪只做一次更新，接著重跑外部流程取得新數據

---

**USER CONFIG 重點說明**
1. `param_tuning_file`
- 參數替換的模板檔
- 會覆蓋 output 子資料夾內同名檔案

2. `@modifications`
- 定義要修改的檔案與替換規則
- 同時也是複製檔案的來源
- 可新增 `{ file => 'xxx.pl' }` 只複製不修改

3. `@run_commands`
- 每個 output 子資料夾要跑的指令
- 若 `param_tuning_file` 改名，這裡通常也要改

4. `@collect_file_keywords` / `@collect_data_keys`
- 控制收集檔案與數據 key 的範圍

5. `%default_param_map`
- 參數對應的唯一來源
- 影響調參與收集（預設 key）

6. `@select_params`
- 指定只調哪些參數

---

**CLI 參數一覽**
- `--auto`：進入自動調參循環
- `--full`：先重建 output 子資料夾
- `--no-tune`：只建 output + 跑指令 + 收集資料
- `--collect`：收集 + 單次計算（不重建 output、不重跑指令）
- `--emit-merged`：輸出 merged_data.csv
- `--tuning-file`：指定 param_tuning_file（`--template` 亦可）
- `--data`：指定 merged_data.csv 檔案路徑
  - `--collect` / `--auto` / `--no-tune` 時：做為輸出路徑
  - 其他模式時：做為輸入路徑
- `--params`：指定只調哪些參數
- `--model add|mul`：調參模式
- `--step`：每輪最大變化量
- `--max-rounds`：最大迭代輪數
- `--max-iter`：非 auto 模式的迭代次數
- `--min-param / --max-param`：參數上下限
- `--out`：指定 tuned_params.csv 輸出檔名
- `--report`：指定 tuning_report.csv 輸出檔名
- `--join-key`：指定 join key（預設 File_Path）
- `--output-dir`：output 目錄
- `--target`：目標 CSV 檔案
- `--no-clean`：不清除既有 output 目錄（搭配 --full 使用）

---

**常見問題與除錯**
- 找不到 target：`File_Path` 不一致，請確認 `target.csv` 的路徑與收集結果一致
- 收不到資料：`@collect_file_keywords` 太嚴格或 `@collect_data_keys` 設錯
- 沒有可調參數：`%default_param_map` 沒有對應到輸出欄位
- 參數完全沒變：可能 `@select_params` 把參數都篩掉了
- 調參不收斂：可嘗試調整 `step` / `max_rounds` / `model`

---

**建議操作順序**
1. 先用 `--no-tune --full` 確認 output 與收集資料正常
2. 確認 `%default_param_map` 與 `target.csv` 對應正確
3. 再用 `--auto --full` 進行自動調參
