## 示例：数据清洗任务
- 输入：CSV 销售数据（字段：date, store_id, revenue, channel）
- 目标：
  1. 统一日期格式。
  2. 填补缺失 revenue，规则：同门店 7 日移动平均。
  3. 生成数据质量概览表。
- 输出：`output/clean_sales.csv` + `output/data_quality.md`
