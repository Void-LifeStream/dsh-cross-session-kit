# inbox.ps1 - 跨会话信箱检查（~/.dsh/inbox/）
#
# 为什么有它：信箱是"拉取式"的 —— 写信的人不知道对方读没读，收信人也不知道有没有新信。
# 这个脚本把"有没有新信"变成一次开工/一轮回复就能看到的一句事实。
#
# 判据（**自包含，不需要任何额外状态文件**；当前 **v5.1**）：
#   1) **小节 = 二级标题**（`## `，不是 `### `）；**一节 = 一封信**。
#   2) **回执 = 一行以 `> ✅` 开头**，写在你读完的那一节的末尾（它是游标：「这之前的我都读过了」）。
#   3) 判据 = **最后一个小节里有没有回执** ⇒ 有 = 已读到最新；没有 = 有新信。
#   4) **最后一节的署名若是我自己 ⇒ 直接判"已读到最新"**（自己投的节不需要回执）。
#
#   ⚠️ 判据**不看字节数、也不看时间格式** —— 那两者都是被实测淘汰的：
#      v1「文件比回执里记的字节数大」   ✗ 回执自身写入也让文件变大 ⇒ 恒报有新信
#      v2「回执必须带 HH:MM」          ✗ 写 `12:5x` 占位就不被识别 ⇒ 退回去认更早那条
#      v3「回执里记'至 N B'」          ✗ 鸡生蛋：写它就改变大小，那个 N 永远对不上
#      v4「最后一条回执之后有无实质内容」△ 能自洽，但仍依赖"回执必须写末尾"这条脆弱约定
#      v5「最后一个小节里有没有回执」   ✓ 一节一游标，结构天然
#      v5.1「+ 排除自己投的那一节」     ✓ 否则刚写完回复就被自己报"有新信"
#
# USAGE:
#   pwsh -File inbox.ps1              # 完整输出（人看）
#   pwsh -File inbox.ps1 -Quiet       # 只在"我有新信还没读"时输出一行；否则零输出
#   pwsh -File inbox.ps1 -All         # 连"与我无关的"信箱文件也列出来（看别人在聊什么）
#
# 退出码：0 = 没有待我读的新信；2 = 有（方便别的脚本判断）
#
# 注意：本脚本**只读**，不会替你回执、也不会改任何文件。
# 回执是"话"，由你自己写进那封信里（约定见同目录 README.md）。

param(
  [string]$SessionId = $env:DSH_SESSION_ID,
  [switch]$Quiet,
  [switch]$All
)

$ErrorActionPreference = 'Continue'
$dir = Join-Path $env:USERPROFILE '.dsh\inbox'
$me  = ''
if ($SessionId -and $SessionId.Length -ge 6) {
  $me = $SessionId.Substring($SessionId.Length - 6)
}

if (-not (Test-Path -LiteralPath $dir)) { if (-not $Quiet) { Write-Host '    (no inbox directory)' }; exit 0 }

$files = @(Get-ChildItem -LiteralPath $dir -Filter 'to-*.md' -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notmatch '\.bak-' })

$incoming = @()   # 写给我的，且我还没读到最新
$outgoing = @()   # 我投过小节的，看对方回执到哪了
$others   = @()   # 与我无关的（只在 -All 时收集）

foreach ($f in $files) {
  # ⚠️ 单个坏文件不该让整个检查崩掉（2026-10-16 加）：读不了就跳过并说明。
  try {
    $raw = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
  } catch {
    if (-not $Quiet) { Write-Host ('    ⚠️ 读不了 ' + $f.Name + '（' + $_.Exception.Message + '）—— 已跳过') }
    continue
  }
  $size = (Get-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue).Length
  if (-not $size) { $size = $raw.Length }

  $tick = [string][char]0x2705
  # 小节 = **二级标题**（`## ` 后跟空格/制表符）。
  # ⚠️ 写成 `^##[^\r\n]*` 会连 `### 子标题` 一起匹配（`### ` 同样以 `##` 开头！），
  #    「最后一个 `##` 小节」会错位成末尾那个 `###`，判据随之看错范围（2026-10-16 实测修）。
  $sections = [regex]::Matches($raw, '(?m)^##[ \t][^\r\n]*')
  $lastTitle = if ($sections.Count -gt 0) { $sections[$sections.Count - 1].Value } else { '' }
  $sig = if ($me) { '#' + [regex]::Escape($me) } else { $null }

  # 身份判定：**看小节标题里的署名**。
  # ⚠️ 以前用 `$raw.Contains("#$me")`（全文搜索）⇒ 别人在正文里**引用**我，也会被算成"我写过字"，
  #    "寄出"列表的语义就歪了（2026-10-16 修）。
  $isToMe = [bool]($me -and $f.Name -eq "to-$me.md")
  $iWrote = [bool]($sig -and ($sections | Where-Object { $_.Value -match $sig }))
  if (-not ($isToMe -or $iWrote -or $All)) { continue }

  # 回执行必须有**引用块行首**（`> ✅`）—— 挡掉两个实测踩到的误报：
  #   ① 正文里出现的 `✅`（本鲸 13:0x 的回信正文里就有一行 `- ✅ …`，整个文件被误判成"已回执"）；
  #   ② 说明用的「示例」行（`#235403` 当初留的那行占位）。
  $scope = if ($sections.Count -gt 0) { $raw.Substring($sections[$sections.Count - 1].Index) } else { $raw }
  $acks = @([regex]::Matches($scope, ('(?m)^[ \t]*>[ \t]*' + $tick + '[^\r\n]*')) |
            Where-Object { $_.Value -notmatch '示例' })
  $ackSeen = $acks.Count -gt 0
  $ackBytes = $null
  if ($ackSeen) {
    $mm = [regex]::Match($acks[$acks.Count - 1].Value, '至\s*(\d+)\s*B')   # 只为显示留个参考值；判据**不用**它
    if ($mm.Success) { $ackBytes = [int]$mm.Groups[1].Value }
  }

  # 最后一节的署名是我自己 ⇒ 那节是我投的，没有"待我读"的东西（v5.1）
  $mine = [bool]($sig -and ($lastTitle -match $sig))

  if ($isToMe) {
    $state = if ($mine -or $ackSeen) { 'read' } else { 'unread' }
    $incoming += [pscustomobject]@{ Name = $f.Name; Size = $size; Ack = $ackBytes; State = $state }
  }
  if ($iWrote -and -not $isToMe) {
    # **final ACK**（2026-10-16 由用户点出后补上）：最后一节标题里带 `[FINAL-ACK]` ⇒
    # 本轮往来到此为止、不必再等回执。
    # 为什么需要它：① 两边都在归档阶段时会**无限互回**（A 回"我读了" → B 回"我也读了" → …）；
    # ② 更隐蔽的是 —— **"对方已归档"和"对方还没回"在界面上长得一模一样**
    #    （本机那条老毛病："没数据"与"没连上"同形）。标一下，等待才有尽头。
    $finalMark = [bool]($lastTitle -match 'FINAL-ACK')
    $state = if ($finalMark) { 'final' } elseif ($ackSeen) { 'acked' } else { 'pending' }
    $outgoing += [pscustomobject]@{ Name = $f.Name; Size = $size; Ack = $ackBytes; State = $state }
  }
  if ($All -and -not $isToMe -and -not $iWrote) {
    $others += [pscustomobject]@{ Name = $f.Name; Size = $size; Sections = $sections.Count; Ack = $ackSeen }
  }
}

# v5 只有两种收件状态：读过了 / 还没读（判据 = "最后一个小节末尾有没有 `> ✅`"）
$fresh = @($incoming | Where-Object { $_.State -eq 'unread' })

if ($Quiet) {
  if ($fresh.Count -gt 0) {
    foreach ($r in $fresh) {
      Write-Host ("    📬 信箱有新信：{0}（{1} B，这一节末尾还没有 `> ✅` 回执）—— 去读，然后**在该节末尾**回执" -f $r.Name, $r.Size)
    }
    exit 2
  }
  exit 0
}

Write-Host ''
Write-Host ('[4] INBOX  (~/.dsh/inbox/)     我 = #' + $(if ($me) { $me } else { '未知' }))
if ($incoming.Count -eq 0 -and $outgoing.Count -eq 0 -and $others.Count -eq 0) {
  Write-Host '    （没有与我相关的纸条）'
} else {
  foreach ($r in $incoming) {
    $tag = switch ($r.State) {
      'unread' { '⚠️ 还没读（最后一个小节末尾没有 `> ✅` 回执）' }
      default  { '已读到最新（最后一个小节末尾有 `> ✅`）' }
    }
    Write-Host ('    收件 · ' + $r.Name + '  [' + $r.Size + ' B]  ' + $tag)
  }
  foreach ($r in $outgoing) {
    $tag = switch ($r.State) {
      'final' { '🔚 已宣告结束（[FINAL-ACK]）—— 不必再等对方回执' }
      'acked' { '✅ 对方已回执到最新' }
      default { '⏳ 对方还没回执（最后一个小节末尾没有 `> ✅`）' }
    }
    Write-Host ('    寄出 · ' + $r.Name + '  [' + $r.Size + ' B]  ' + $tag)
  }
  foreach ($r in $others) {
    Write-Host ('    旁观 · ' + $r.Name + '  [' + $r.Size + ' B, ' + $r.Sections + ' 节]  ' + $(if ($r.Ack) { '末节有回执' } else { '末节无回执' }))
  }
}
Write-Host '    （回执 = 一行 `> ✅ <时间> 已读`，写在「你读完的那一节」的末尾；一节一封信。**别再写 `（至 N B）`**）'
Write-Host ''

if ($fresh.Count -gt 0) { exit 2 } else { exit 0 }
