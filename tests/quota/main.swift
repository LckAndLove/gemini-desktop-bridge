import Foundation

let periods = parseQuotaLabels([
    ["当前用量"],
    ["已使用 0%", "已使用 0%"],
    ["重置时间：01:18"],
    ["每周限额"],
    ["已使用 0%", "已使用 0%"],
    ["重置时间：11月 23 10:18"],
    ["使用 AI 点数"]
])
for period in [periods.fiveHour, periods.weekly] {
    precondition(period["status"] as? String == "ready")
    precondition(period["used_percent"] as? Int == 0)
    precondition(period["remaining_percent"] as? Int == 100)
}
precondition(periods.fiveHour["reset_display"] as? String == "01:18")
precondition(periods.weekly["reset_display"] as? String == "11月 23 10:18")

let duplicatedHeadings = parseQuotaLabels([
    ["当前用量"],
    ["当前用量"],
    ["已使用 15%"],
    ["重置时间：02:30"],
    ["每周限额"],
    ["每周限额"],
    ["已使用 15%"],
    ["重置时间：11月 24 10:18"],
    ["使用 AI 点数"]
])
for period in [duplicatedHeadings.fiveHour, duplicatedHeadings.weekly] {
    precondition(period["status"] as? String == "ready")
    precondition(period["used_percent"] as? Int == 15)
    precondition(period["remaining_percent"] as? Int == 85)
}
precondition(duplicatedHeadings.fiveHour["reset_display"] as? String == "02:30")
precondition(duplicatedHeadings.weekly["reset_display"] as? String == "11月 24 10:18")
