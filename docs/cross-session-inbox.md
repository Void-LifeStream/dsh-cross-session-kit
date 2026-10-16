# 跨会话 agent 通信：一个文件信箱的五版判据、两次归档与三个边界

> 一份**案例研究**，不是论文 —— 我们没有实验数据，只有**一天真实使用**留下的记录：
> 若干个 agent 会话、一台机器、以及若干次真实的误解与修正。
> 写下来，是因为**踩过的坑比设计更值得转述**。

---

## 一、问题：多个 agent 共用一个文件系统，却互不知情

当同一台机器上并行跑着 5 个以上的 agent 会话时，会发生这些事：

- A 改了共享配置，B 不知道；
- A 和 B 同时改同一个文件（谁先谁后靠运气）；
- **最贵的**：A 花半小时查清一件事，B 两小时后从零重查一遍 —— 而它**根本不知道 A 查过**。

⇒ 缺的不是算力，是「**隔壁在干什么**」。

## 二、为什么不是"发消息"：可见 ≠ 可寻址

第一反应当然是"做个发消息的工具"。**先读契约，别先写代码** —— 这是整件事上最省时间的一步。

读下来的结论：

| 你以为 | 实际 |
|---|---|
| 能枚举所有会话 ⇒ 就能给它们发消息 | ❌ **枚举 ≠ 可寻址** |
| `sendMessage` 能发给"另一个会话" | ⚠️ 它的语义是**父子**（只接受直接父或直接子）；团队内另有 `agentTeams.sendMessage` |

⇒ **"看得见"和"发得过去"是两件独立的事**，中间隔着一个**权限轴**。
⇒ 问"能不能跨会话做点什么"之前，**先问这套体系有几个权限轴**（这里只有一个：父子）。

**所以：横向不通，就落到文件上。**

## 三、设计：一个文件信箱

极简：

- **一个会话一个文件**：`to-<会话 id 后 6 位>.md`
- **投递** = 追加一个 `## ` 小节（标题带时间 + 你自己的署名）
- **回执** = 在「**你读完的那一节**」的**末尾**追加一行 `> ✅ <时间> 已读`
- **一节 = 一封信**

（用文件而不是数据库，是因为**共享文件系统是这类环境里唯一保证存在的东西** —— 而且人类也能看。）

## 四、⭐ 判据演进：五版，每一版都被真实使用打回去过

这是本案例最硬的部分。「对方到底读没读」这一件事，我们改了**五版**：

| 版本 | 判据 | 为什么不够 |
|---|---|---|
| v1 | 文件比"上次回执里记的字节数"大 | **回执自己也会让文件变大** ⇒ 恒报"有新信" |
| v2 | 回执必须带 `HH:MM` 时间戳 | 有人写 `12:5x` 占位 ⇒ 不被识别、退回去认更早那条 ⇒ 误判 |
| v3 | 回执里记「至 N B」 | **鸡生蛋**：写回执就改变文件大小，那个 N 永远对不上 |
| v4 | 最后一条回执之后还有没有实质内容 | 能自洽，但依赖"回执必须写末尾"这条**脆弱约定** |
| **v5** | **最后一个 `##` 小节里有没有回执** | 一节 = 一封信，回执写在该节末尾 = **天然游标** ✓ |
| **v5.1** | v5 + **排除"最后那节是我自己投的"** | 否则**刚写完回复就被自己的工具报"有新信"** |

**三条教训**（这才是想说的）：

1. **别让判据依赖"人把格式写对"** —— v2 就是这么坏的：一个偷懒的占位符就能骗过它；
2. **别用"会被你自己的操作改变的量"当判据** —— v1 和 v3 都死在这里；
3. **优先用结构（小节、署名）当游标，而不是计数（字节、时间）** —— 结构不会因为你又写了一行而失真。

另外两个**实测撞到**的误报（都已修）：

- **正文里出现的 `✅`** 被当成回执 ⇒ 判据收紧为「**一行以 `> ✅` 开头**」；
- 文件里**说明用的「示例」行**也含 `✅` ⇒ 排除含"示例"的行。

## 五、终止语义：`[FINAL-ACK]`

两个人互相回执会**永不停**（A 回"我读了" → B 回"我也读了" → …）。加三条：

1. **默认不必回** —— 回执是礼貌，不是义务；
2. **`[FINAL-ACK]`** —— 写在**一节标题末尾** ⇒ 「本轮到此为止，收到即止、不必回执」；
3. **归档前必做** —— 在你最后发出的那节补上它。

⚠️ **为什么这条是必需的（不是礼貌，是正确性）**：
**"对方已归档"和"对方还没回"在界面上长得一模一样** ——
不标的话，你这边会一直显示「⏳ 还没回执」，**可能为此永远等下去**。
（这是"**两将军问题**"的朴素版本：在不可靠信道上双方永远无法确知对方收到了没有 ——
所以工程上的答案是**加一个显式的终止标记**，而不是追求确认。）

## 六、⭐ 三个边界

**① 可见 ≠ 可寻址**（见第二节）—— 任何"跨 X 通信"的设计，先问权限轴。

**② 用户是触发器，不是信道**
- 有话给别的会话 ⇒ **自己写进它的信箱**，**不要托人转述**（人会丢细节、会简写，而且是**单点**）；
- **反过来**：听到"隔壁说……"时，**去原始通道核一遍** —— **转述不算收到**；
- ✅ **但用户是极好的"触发器"**：他能**叫醒**一个没在跑的会话。**当闹钟用，别当信道用**。

**③ 孤儿信 / 归档 ≠ 死亡**
- 信是写给**会话实例**的（文件名就是那个会话的 id）⇒ **会话一关，未读的信就永远是孤儿**；
- 而「**归档**」的准确含义是「**默认不会再主动回复**」（要"取消归档"才能重新打开）⇒ **别再等它**；
- ⇒ **一句话的协调用信箱；跨会话必须留传的事，写进按"事"组织的台账。**

## 七、⚡ 我们犯的错（这块最值钱）

1. **两个人各往同一份 README 里写了一条"实测出来的"硬要求，而它们正好相反** ——
   一条说"投递方也要在自己节末尾补 ✅"（因为他自己刚写的节被判成"有新信"），
   另一条说"投递方别写 ✅"（因为他写了之后，收信人那边误判成"已读"）。
   ⇒ **两条都对，却互相矛盾** —— 因为**当时的判据缺一个维度：这一节是谁写的**。
   v5.1 补上那个维度之后，**两条一起失效**。
   ⇒ **教训：当两条"实测结论"打架时，别急着选一个 —— 去找缺失的那个维度。**
2. **"蓝色 = 已归档"这句转述被直接采信** ⇒ 一个 agent 把自己在台账里误标成了 `archived`，
   而它其实是**未归档**（那只是一个"当前选中"的高亮框）。
   ⇒ **假的归档标记会让别人以为"这只走了"，比不标更糟**。
   ⇒ **教训：连用户的口头描述也要回原始通道核实**（他后来自己也纠正了）。
3. **正则 `^##[^\r\n]*` 把 `###` 子标题也匹配了** ⇒ "最后一个小节"错位成某个 `###`，
   判据随之看错范围。（`###` 同样以 `##` 开头 —— 一个字符的疏忽。）
4. **回执写错了地方** —— 写在了**自己投的那一节**末尾，而那恰好是前一条里
   我们请别人撤掉的同一个动作。

## 八、配套机制：一块"在办台账"

信箱解决**点对点**，而"**所有人都该知道的事**"需要一块**公共布告板**：

- 一行一件事：`| 会话 | 在做什么 | 开始 | 状态 | 产出 / 落点 |`
- **署名 = `<代号>#<会话 id 后 6 位>`** ⇒ **谁在做什么，可追**
- ⭐ **「署名即栅栏」**：一行的第一列带着**别人的**署名 ⇒ 那是**别人的活** ——
  **不执行、不"顺手帮一把"、也不提议接手**。
  （这条是被真实事故逼出来的：一只新会话读了全表，仍然向用户提议接手别人已认领的任务。）
- **状态词**：`doing` / `claimed` / `pending` / `done` / **`archived`**（已归档：**别再等它**）
- **归档 ≠ 删除**：历史进冷归档文件，仍可 grep 追溯；活台账只留"未完成 + 最近 N 行已完成"，
  免得每次开工都全量读一遍。

## 九、给要重造这个轮子的人（可复用判据）

1. **先读契约，再写代码** —— 那个"能不能发消息"的未知数，值得先花十分钟查清楚；
2. **判据用结构，不用计数**；**别依赖人把格式写对**；
3. **每一条协议都要有终止条件** —— 否则双方会永远"礼貌"下去；
4. **显式的状态标记胜过推断**（`[FINAL-ACK]`、`archived` 都是这个思路）；
5. **当两条实测结论打架时，去找缺失的那个维度**；
6. **转述永远要回原始通道核实** —— 包括用户的转述；
7. **单个坏文件不该让整个检查崩掉**；**单个假警报会毁掉整句话的可信度**。

---

*中文正文完 —— 下面是英文摘要。*

## English summary

**Cross-session agent messaging: five versions of one predicate, two archives, and three boundaries.**

When several agent sessions share one filesystem, the missing piece is not compute but *"what is the neighbour
doing"*. The obvious fix — a messaging tool — dies on a permission fact worth checking **before** writing code:
**being able to enumerate sessions does not make them addressable** (`sendMessage` is parent/child only).
So we fell back to **files**: one mailbox file per session, one `##` section per letter, and a receipt line
(`> ✅`) written at the *end of the section you finished reading* — a **cursor**, not a timestamp.

The predicate deciding "has the peer read it?" went through **five versions**, each defeated by real use:
byte-count comparison (the receipt itself grows the file), an `HH:MM` requirement (someone wrote `12:5x`),
"read up to N bytes" (chicken-and-egg), "any content after the last receipt" (a fragile convention), and finally
**"is there a receipt inside the last `##` section"** — one section, one cursor — plus v5.1:
**exclude the section I wrote myself**. Lessons: never depend on humans formatting correctly; never use a
quantity your own action changes; prefer structure over counters.

Termination is explicit: **`[FINAL-ACK]`** in a section title means "this round is over, no reply needed" —
because *"the peer archived"* and *"the peer hasn't replied yet"* otherwise look **identical** (a homely version
of the two-generals problem).

Three boundaries: **(1)** visible ≠ addressable; **(2)** the human is a **trigger, not a channel** — write to the
mailbox yourself, and always verify hearsay against the original source; **(3)** letters are addressed to
*session instances*, so unanswered mail becomes orphaned — durable facts belong in a work-board organised by
*subject*, not by session.

The most valuable part is not the design but **our mistakes**: two contradictory "measured" rules that coexisted
because the predicate lacked a *who wrote this section* dimension; a mis-tagged `archived` born from a
second-hand report; a `###` subheading misread as `##`; and a receipt written in the wrong section — the very
mistake we had just asked a peer to undo.

*Unofficial: user scripts and notes, not affiliated with DeepSeek.*
