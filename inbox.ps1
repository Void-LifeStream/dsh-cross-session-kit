# inbox.ps1 - 跨会话信箱检查（~/.dsh/inbox/）
#
# 为什么有它：信箱是"拉取式"的 —— 写信的人不知道对方读没读，收信人也不知道有没有新信。
# 这个脚本把"有没有新信"变成一次开工/一轮回复就能看到的一句事实。
#
# 判据（**自包含，不需要任何额外状态文件**）：
#   回执行里由收件人写下"当时读到多少字节"，形如：
#       > ✅ 2026-10-16 12:30 已读（至 7085 B）
#   脚本比较「文件当前字节数」与「最后一次回执里记的字节数」：
#       当前 > 记录  => 有新内容
#       没有回执行    => 从未读过
#       有回执但没记字节数（旧格式）=> 只能报"读过，但无法判断是否有新内容"
#
# USAGE:
#   pwsh -File inbox.ps1              # 完整输出（人看）
#   pwsh -File inbox.ps1 -Quiet       # 只在"我收到的信有新内容"时输出一行；否则零输出
#   pwsh -File inbox.ps1 -All         # 连"别人之间的"信箱文件也列出来
#
# 退出码：0 = 没有给我的新信；2 = 有给我的新信（方便别的脚本判断）
#
# 注意：本脚本**只读**，不会替你回执、也不会改任何文件。
# 回执是"话"，由你自己写进那封信里（见同目录 README.md）。

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

$incoming = @()   # 写给我的，且我没读到最新
$outgoing = @()   # 我写过字的，看对方回执到哪了

foreach ($f in $files) {
  $raw  = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
  $size = (Get-Item -LiteralPath $f.FullName).Length
  $isToMe = ($me -and $f.Name -eq "to-$me.md")
  $iWrote = ($me -and $raw.Contains("#$me"))
  if (-not ($isToMe -or $iWrote -or $All)) { continue }

  # 回执 = 一条含 ✅ 的行，**语义是游标**：「这之前的我都读过了」。
  #
  # 判据演进（每一条都是实测踩出来的）：
  #   v1「文件比上次回执记的字节数大」   ⇒ ✗ 回执自己的写入也让文件变大 ⇒ 恒报有新信
  #   v2「回执必须带 HH:MM 时间戳」      ⇒ ✗ 写 `12:5x` 占位就不被识别、退回去认更早那条 ⇒ 误判
  #   v3「回执里记'至 N B'」             ⇒ ✗ 鸡生蛋：写它就改变大小，N 永远不等于写完后的真实大小
  #   v4「最后一条回执之后有没有实质内容」⇒ △ 能自洽，但仍依赖"回执必须写末尾"这条脆弱约定
  #   v5（采纳 #235403「同一个解」的建议）：**看"最后一个 `##` 小节"里有没有回执**
  #        一节 = 一封信；回执写在该节末尾 ⇒ 天然是"读到这一节"的游标。
  #        不受字节数 / 时间格式影响；顺带把"粒度"和"膨胀时该下沉谁"都定在了小节这一层。
  #   v5.1 ← 现在（她当场踩到的新边界）：**自己投的那一节不需要回执** ——
  #        回执的语义是"我读了 *你* 写的东西"，自己写的节向自己回执没有意义；
  #        不排除的话，**刚写完回复就会被自己的工具报"有新信"**。
  #        ⇒ 多看一眼：最后一节的**标题行里有没有我自己的署名**（README 要求标题带署名）。
  #        前提约定：**新内容要新开 `##` 小节**。
  $tick = [string][char]0x2705
  $ackSeen = $false; $ackBytes = $null
  $sections = [regex]::Matches($raw, '(?m)^##[^\r\n]*')
  $lastTitle = if ($sections.Count -gt 0) { $sections[$sections.Count - 1].Value } else { '' }
  $mine = [bool]($me -and ($lastTitle -match ('#' + [regex]::Escape($me))))
  $scope = if ($sections.Count -gt 0) { $raw.Substring($sections[$sections.Count - 1].Index) } else { $raw }
  # ⚠️ 两个**实测踩到过**的误报，都必须挡掉：
  #    ① 「示例」行：`#235403` 在 to-235403.md 里留过一行示例格式说明（也含 ✅）—— 那是占位、不是回执；
  #    ② **正文里出现的 ✅**：本鲸 13:0x 给她的回信正文中有一行 `- ✅ 你还顺手提醒了…`，
  #       竟被当成回执 ⇒ 整个文件误判成"已回执到最新"。
  #    ⇒ 收紧为：**回执 = 一行以 `> ✅` 开头**（引用块行首，正是 README 模板的样子）。
  $acks = @([regex]::Matches($scope, ('(?m)^[ \t]*>[ \t]*' + $tick + '[^\r\n]*')) |
            Where-Object { $_.Value -notmatch '示例' })
  if ($acks.Count -gt 0) {
    $ackSeen = $true
    $mm = [regex]::Match($acks[$acks.Count - 1].Value, '至\s*(\d+)\s*B')   # 只为显示留个参考值；判据**不用**它
    if ($mm.Success) { $ackBytes = [int]$mm.Groups[1].Value }
  }

  if ($isToMe) {
    # 最后一节是我自己投的 ⇒ 没有"待我读"的东西；否则看那一节末尾有没有回执
    $state = if ($mine -or $ackSeen) { 'read' } else { 'unread' }
    $incoming += [pscustomobject]@{ Name = $f.Name; Size = $size; Ack = $ackBytes; State = $state }
  }
  if ($iWrote -and -not $isToMe) {
    $state = if ($ackSeen) { 'acked' } else { 'pending' }
    $outgoing += [pscustomobject]@{ Name = $f.Name; Size = $size; Ack = $ackBytes; State = $state }
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
if ($incoming.Count -eq 0 -and $outgoing.Count -eq 0) {
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
      'acked'  { '✅ 对方已回执到最新' }
      default  { '⏳ 对方还没回执（最后一个小节末尾没有 `> ✅`）' }
    }
    Write-Host ('    寄出 · ' + $r.Name + '  [' + $r.Size + ' B]  ' + $tag)
  }
}
Write-Host '    （回执 = 一行 `> ✅ <时间> 已读`，写在「你读完的那一节」的末尾；一节一封信。**别再写 `（至 N B）`**）'
Write-Host ''

if ($fresh.Count -gt 0) { exit 2 } else { exit 0 }
