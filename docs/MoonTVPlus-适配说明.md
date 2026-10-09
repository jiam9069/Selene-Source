# MoonTVPlus 适配说明

本文记录本分支为适配 **MoonTVPlus** 后端所做的全部改动、依据与验证方式。

- 上游客户端：<https://github.com/MoonTechLab/Selene>
- 对比后端 A（客户端原本对齐的）：MoonTV v100，即 [`MoonTechLab/LunaTV`](https://github.com/MoonTechLab/LunaTV) `v100.1.3`
- 对比后端 B（本次适配目标）：[`mtvpls/MoonTVPlus`](https://github.com/mtvpls/MoonTVPlus) `v226.1.0`

所有结论都来自对两个后端源码的逐接口 diff，以及在一个真实运行的
MoonTVPlus 实例（`v226.1.0`，Kvrocks 存储，70 个采集源 + 3 个 Emby 源 +
7 个网络直播间）上的实际抓包验证。

> **设计原则：向后兼容。** 所有适配都通过 `GET /api/server-config` 做能力探测
> （见 `lib/services/backend_service.dart`），只在识别为 MoonTVPlus 时才启用对应分支，
> 因此原版 MoonTV v100 / Helios 后端仍然可以正常使用。

---

## 1. 关键差异总览

| 差异点 | MoonTV v100 | MoonTVPlus v226 | 客户端原行为 | 适配方式 |
|---|---|---|---|---|
| `/api/health` | 不存在 | 不存在 | `checkConnection()` 恒返回 false | 改用 `/api/server-config` |
| 登录 Cookie 有效期 | 7 天 | access token **4 小时** + 60 天 refresh token | 无续期逻辑，4 小时后全部 401 → 被踢回登录页 | 401 时调 `/api/auth/refresh` 换发后重试 |
| Emby 私人影库 | 无 | 有，源标识 `emby` / `emby_<key>` | `/api/detail` 返回 400「无效的API来源」 | 改走 `/api/emby/detail` 并转换响应结构 |
| Emby 搜索结果的 `episodes` | 不适用 | **恒为空数组** | 认为该条目没有可播放剧集 | 检测到 `episodes` 为空时回源拉详情 |
| `proxyMode` 字段 | 无 | `/api/detail` 新增，标记源是否需服务端代理 m3u8 | 忽略该字段，直接播放原地址 | 开启时改走 `/api/proxy/vod/m3u8` |
| 相对播放地址 | 无 | 私人影库返回 `/api/openlist/play?...` 等站内相对地址 | 播放器拿到相对地址无法播放 | 统一补全为绝对地址 |
| `/api/search/resources` | 仅采集源 | 采集源 + 源脚本条目 `{key,name,script:true}`（**无 `api` 字段**） | 本地搜索拿空 URL 去请求，空等超时 | 过滤掉无 `api` 的条目 |
| 网络直播（WebLive） | 无 | `/api/web-live/sources`、`/api/web-live/stream` | 无任何入口 | 新增模型 / 服务 / UI，并入直播列表 |
| AI 问片 | 无 | `POST /api/ai/chat`（SSE 流式） | 无任何入口 | 新增聊天界面与服务（见 2.8、2.8.1） |
| 私人影库页面 | 无 | `/private-library`，另有 `/api/emby/{sources,views,list}` | 无任何入口，只能靠聚合搜索偶然命中 | 新增浏览页并加入底栏与用户菜单（见 2.9） |

---

## 2. 逐项说明

### 2.1 连接检查用了不存在的接口

`lib/services/api_service.dart` 的 `checkConnection()` 原本请求 `GET /api/health`。

实测：该路由在两个后端都不存在，请求会被 Next.js 中间件拦下，
**带 Cookie 时返回 404，不带 Cookie 时返回 401**，因此该函数永远返回 false。

改为请求两端都提供且**无需登录**的 `GET /api/server-config`。

### 2.2 登录态 4 小时后失效

MoonTVPlus 把登录 Cookie 升级成了 short-lived access token + refresh token
（`src/lib/token-config.ts`）：

```ts
ACCESS_TOKEN_AGE: 4 * 60 * 60 * 1000,        // 4 小时
REFRESH_TOKEN_AGE: 60 * 24 * 60 * 60 * 1000, // 60 天
RENEWAL_THRESHOLD: 10 * 60 * 1000,           // 剩余 10 分钟续期
```

中间件对超过 4 小时的 token 在处理 `/api/*` 时**直接返回 401**
（页面请求放行，交由前端刷新）。原客户端没有任何续期逻辑，
收到 401 就清除登录信息并跳登录页，所以**用满 4 小时后必然掉线**。

适配：新增 `lib/services/backend_service.dart`，在收到 401 时调用
`POST /api/auth/refresh` 换取新的 `auth` Cookie 并原样重试一次请求。
所有带认证的请求都经过 `ApiService._sendWithAuthRetry(...)`，
收藏、播放记录、搜索历史等直接发起的请求也已改走该路径。

刷新请求做了并发合并（同一时刻只发一次），避免多个并行请求同时拿着旧 Cookie 去刷新。

### 2.3 Emby 私人影库源点不开（影响最大）

这是本次适配解决的核心问题，链条上有两个断点。

**断点一：`/api/detail` 不支持 Emby 源。**

MoonTVPlus 的 `/api/detail` 只处理采集源、`openlist` 与 `script:` 源；
`emby` / `emby_<key>` 不在其中，会走到末尾的「找不到匹配的 API 站点」分支，
返回 **400 `{"error":"无效的API来源"}`**。

实测（`source=emby_net&id=601858`）：

```
HTTP 400
{"error":"无效的API来源"}
```

Emby 详情真正的接口是 `GET /api/emby/detail?id=<itemId>&embyKey=<key>`，
响应结构与 `/api/detail` 完全不同：

```jsonc
// 电影
{"success":true,
 "item":{"id":"601858","title":"小姐与流浪汉","type":"movie","overview":"",
         "poster":"https://.../Items/601858/Images/Primary?api_key=...",
         "year":"1955","rating":0,
         "playUrl":"https://.../Videos/601858/stream?Static=true&api_key=..."},
 "episodes":[]}

// 剧集
{"success":true,
 "item":{"id":"ser_...","title":"三毛流浪记","type":"tv", ...},
 "episodes":[{"id":"itm_...","title":"4M","episode":91,"season":2,
              "overview":"","playUrl":"https://.../Videos/itm_.../stream?..."}]}
```

**断点二：搜索结果里 Emby 条目的 `episodes` 恒为空。**

搜索接口（`/api/search` 与 `/api/search/ws`）为 Emby 结果构造的对象里
`episodes: []`、`episodes_titles: []`——**播放地址只在详情接口里**。

实测抓取的搜索事件（同一关键词下 73 个源，其中 3 个 Emby 源共 41 条结果）：

```jsonc
{"id":"601858","title":"小姐与流浪汉","source":"emby_net",
 "source_name":"Hohai公益Emby","episodes":[],"episodes_titles":[],
 "type_name":"电影"}
```

原客户端的播放页只有在「搜索结果里完全没有这条」时才会回源拉详情。
由于搜索里**有**这条（只是没有剧集），它就永远不会回源，
最终表现为「卡片能看到、点进去播不了」。

适配（`lib/screens/player_screen.dart`）：

```dart
// 需要回源拉详情的情况：
// 1. 搜索结果里根本没有这条；或
// 2. 有这条但没有可播放的剧集 —— MoonTVPlus 的 Emby / 私人影库源
//    在搜索结果里 episodes 恒为空，只有详情接口才带播放地址。
final needDetail = matched.isEmpty || matched.first.episodes.isEmpty;
```

同时 `ApiService.fetchSourceDetail` 增加 Emby 分支，把
`/api/emby/detail` 的响应转换成客户端统一的 `SearchResult`：
电影取 `item.playUrl` 作为「正片」，剧集逐条取 `episodes[].playUrl`，
多季时标题带 `S<季>` 前缀，并把相对地址补全为绝对地址。

### 2.4 `proxyMode` 被忽略

MoonTVPlus 的源可以开启「代理模式」，此时 m3u8 必须经服务器中转
（`/api/proxy/vod/m3u8?url=&source=`），该接口会连带重写 m3u8 里的
**分片、加密密钥与嵌套 m3u8**，所以客户端只需替换入口地址即可。

MoonTVPlus 前端自身的判断条件（`src/app/play/page.tsx`）是：

```ts
} else if (sourceProxyMode && isM3u8) {
  episodeUrl = `/api/proxy/vod/m3u8?url=${encodeURIComponent(episodeUrl)}&source=${encodeURIComponent(currentSource)}`;
}
```

适配：`SearchResult` 增加 `proxyMode` 字段（`/api/detail` 与搜索事件都会带），
播放时按同一规则包装地址；已经是代理地址的不重复包装，
mp4 / mkv 等非 m3u8 直链不做代理。见 `player_screen.dart#_resolveBackendPlayUrl`。

### 2.5 相对播放地址

私人影库（OpenList）源返回的是站内相对地址，例如
`/api/openlist/play?folder=...&fileName=...`；
Emby 的播放地址则是第三方绝对地址。播放前统一补全，
避免把相对地址直接丢给播放器。

### 2.6 源脚本条目没有 `api` 字段

MoonTVPlus 的 `/api/search/resources`（原注释标注为 OrionTV 兼容接口）
在采集源之后追加了源脚本条目：

```ts
const scriptSites = (await listEnabledSourceScripts()).map((item) => ({
  key: item.key, name: item.name, script: true,
}));
return NextResponse.json([...apiSites, ...scriptSites]);
```

这类条目没有 `api` 字段，只能由服务端执行脚本解析。
客户端的「本地搜索」模式会拿 `resource.api` 拼接下游地址，
拿到空字符串后请求必然失败并等满超时。

适配：`SearchResource` 增加 `isSearchable`（`!disabled && api.isNotEmpty`），
本地搜索与 SSE 本地搜索两处过滤都改用它。
`script:` / `openlist` / `emby_*` 这些只能由服务端解析的源，
在本地搜索模式下会被自然排除。

另外 `/api/search/resources` 现在**不再要求登录**（原版会校验），
但保留登录态调用没有任何副作用。

### 2.7 新增：网络直播（WebLive）

MoonTVPlus 独有的「网络直播」按平台 + 房间号实时解析直播间流：

- `GET /api/web-live/sources` → `[{key,name,platform,roomId,from,disabled}]`
- `GET /api/web-live/stream?platform=&roomId=` → `{url, originalUrl, name, title}`

注意两点：
1. `url` 是**站内相对地址**（`/api/web-live/proxy/proxy.m3u8?url=...`），需要补全；
2. `/api/web-live/proxy/*` **不在中间件的免鉴权白名单里**，播放请求必须带登录 Cookie
   （实测：不带 Cookie 返回 401）。因此播放该频道时需要把 Cookie 作为播放器请求头透传。

实现方式：把每个直播间包装成一个「伪直播源」并入原有直播列表
（key 形如 `weblive|huya|660000`），从而完整复用筛选栏、频道列表与播放器。
新增文件：`lib/models/web_live_source.dart`、`lib/services/web_live_service.dart`；
`LiveChannel` 增加 `headers` 字段用于透传 Cookie。

后端不支持该能力（原版 MoonTV）时静默降级为空列表，不影响普通 M3U 直播源。

### 2.8 新增：AI 问片

`POST /api/ai/chat` 是 SSE 流式接口，协议为：

```
data: {"text":"你好"}
data: {"type":"tool","name":"search_videos","status":"start"}
data: {"type":"tool","name":"search_videos","status":"done"}
data: [DONE]
```

即**增量文本**、**工具调用状态**与结束标记三种事件。
实现要点：按 `\n` 缓冲切分（`data:` 行可能被切到多个 chunk），
用流式 UTF-8 解码器处理跨 chunk 的中文字节。

新增文件：`lib/models/ai_message.dart`、`lib/services/ai_service.dart`、
`lib/screens/ai_chat_screen.dart`；入口在用户菜单，且仅在
`/api/server-config` 返回 `AIEnabled: true` 时显示。

#### 2.8.1 实测修正：工具名映射与进度反馈

首版上线后用户反馈「提示已完成，但没看到任何信息」。实测后端 SSE 本身正常
（一条回答实验为 200+ 个 `{"text":"..."}` 事件、正文从第 1 个事件就开始下发），
问题在客户端渲染层，共三处：

1. **工具名映射不完整**（「已完成」的来源）。实测真实工具名是
   `douban_lookup`、`web_search`、`fetch_page`、`tmdb_lookup`、
   `get_user_favorites`、`get_user_recent`、`get_current_time`、`glob`、`bash`，
   而旧代码只映射了 `search_videos` / `get_video_detail` / `get_hot_movies` /
   `get_recommendations` 这 4 个**并不存在**的名字，导致所有真实工具都落到
   `default` 分支，界面上反复显示没有信息量的「已完成」。现已按真实工具名
   补全映射，未知工具也会保留原名（如「已完成 douban_lookup」）以便排查。
2. **等待期间没有反馈**。模型思考 + 连续调用工具可能持续 20~90 秒，
   期间界面只有一行静态提示，看起来和卡死无异。现在流式期间**始终**显示
   进度行：当前步骤 + `已等待 N 秒` + 最近完成的步骤列表。
3. **高频重绘**。一条回答会触发 200+ 次 `setState`，每次都对整段内容全量
   重解析 Markdown。现改为 100ms 合并增量重绘，且流式输出中的尾部消息用
   纯文本渲染，收到 `[DONE]` 后再切回 Markdown。

另外，若模型调用了工具却没有输出任何正文，兜底提示会说明
「AI 已完成 N 次工具调用，但没有返回文字回答」，而不是留一个空气泡。

#### 2.8.2 富展示与 history 回喂（1.6.12）

2.8.1 让「正在做什么」看得见，2.8.2 让「查到了什么」留下来 —— 流式结束后，
本条消息会固化两样东西并随下一次请求回喂服务端：

| 固化内容 | 字段 | 作用 |
|---|---|---|
| 执行完的工具调用 | `toolCalls`（`name`/`args`/`key`/`result`/`ok`） | 服务端据此重建 `assistant(tool_calls) → tool → assistant` 转录，模型直接复用此前数据，不必在同一会话里重复调用工具 |
| 早期对话的压缩摘要 | `compressedSummaries` | 协议里的 `{"type":"context_compressed","summary":"…"}`；服务端优先按摘要重建上下文，避免上下文再次膨胀 |

请求体形如：

```json
{"message":"…","history":[{"role":"assistant","content":"…",
  "toolCalls":[{"name":"douban_lookup","args":{"query":"流浪地球"},
                "key":"流浪地球","result":"…","ok":true}],
  "compressedSummaries":["【较早对话已压缩】…"]}]}
```

兼容性上做了两件事，保证旧服务端不受影响：

- `AiToolCall.toHistoryJson()` **只**输出 `name/args/key/result/ok`，
  界面用的 `status` 不进 history（服务端不认这个字段）；
- `AiChatMessage.toHistoryJson()` 在没有工具与摘要时**严格只输出**
  `role`/`content` 两个键（有才追加另两个），旧服务端不会收到多余字段。

#### 2.8.3 影片源直出：回答完直接给可点播的源（1.6.12）

用户在 AI 问片里问「有没有 X 的资源」，旧流程要等模型给完文字、再手动去搜索页
搜一次才能看。现在回复一结束就自动搜同名可播放源，以卡片摆到回答下面，点一下
直接进播放器。

流程（纯客户端，不改服务端）：

1. **片名提取** `extractPlayableSourceQueries`（**复数**，1.6.12 之后未发版），按优先级：
   1. 加粗编号榜单项里的片名（`**1. 星际穿越（2014）｜9.4 分**`）——模型写
      「高分片单」时主推的片子走这种写法，实测那次主推的 5 部**一个书名号
      都没有**，只看书名号会全部漏掉；为免把 `**说明：**` 这类加粗小标题误认
      成片名，只认「编号 + 后跟（年份）或 ｜/|」的形式；
   2. 标题类工具参数：`douban_lookup` / `tmdb_lookup` / `search_videos` /
      `search` 的 `args.query`，但**查了却什么都没查到**（`{}` / `[]`）的
      不算数——实测模型会拿「科幻」「记忆」「失忆 寻找妻子 车祸」去试查豆瓣，
      返回的全是空对象，这些词只是它的猜测；
   3. 回复里的 `《片名》`（≤40 字）与 `「片名」`——模型显式标注，全量取用，
      不受搜索词闸门限制（《谁先爱上他的》这类含疑问字的真片名不能被误杀）；
   4. `web_search` 的 `args.query`，必须过闸门。

   取到的片名去重、封顶 **8 个**（`maxPlayableSourceQueries`）。**只取到 1 个
   就自动搜**（旧行为）；**多个不并发搜索**，而是列成一组可点片名按钮，点哪个
   才搜哪个——搜索是串行的、每轮十几秒，替用户猜「哪 5 部」既慢又容易猜错。
   一个都取不到时再退一步看**上一条用户消息**里有没有《片名》，仍然没有才挂
   手动入口。
2. **搜索词闸门** `normalizePlayableSourceQuery`（1.6.12 之后新增，未发版）：影片源检索是
   跨采集源的关键词标题匹配，拿剧情描述去搜必然空手而归（实测「车祸失忆
   寻找妻子」在 **73 个源上 0 条结果**、白等 9 秒）。因此发起搜索前先过闸门：
   - 带 `?`/`？`，或命中中文疑问词（什么/怎么/哪/为什么/多少/谁/介绍/推荐…）
     → 挡下；
   - 纯外文片名（`The Shawshank Redemption`）允许空格、放宽到 60 字；外文
     问句按 who/what/is/are 这类词挡下；
   - 中文带空格的自由词：先剥掉元数据词（豆瓣/评分/剧情/简介/4K/国语…）与
     续集编号（`沙丘 2` → `沙丘2`），**只剩一段**才当片名；剩多段即判定为
     「车祸失忆 寻找妻子」这类剧情描述，挡下；
   - 书名号/引号包裹的一律视为模型标注的片名，只校验长度。
   挡下后**不发注定 0 结果的搜索**，改为在回答下显示「没识别到片名，影片源需要
   按片名搜」+「输入片名搜源」，由用户给出片名后再搜。
3. **搜索**：复用聚合搜索的 `SSESearchService`（`GET /api/search/ws?q=…`），
   `startSearch` 先校验登录态与服务器地址，再挂增量结果 / 进度 / 错误三条流。
   15 秒超时由 `complete` 事件、`stopSearch()` 或页面 dispose 取消。
4. **卡片**：按 `source|id` 去重，**封顶 12 张**，拿满即提前收线；卡片显示
   `年份 · 源名 · 共N集`，海报缺失时用占位图标（离线/测试环境不发网络请求）。
   点卡片进 `PlayerScreen(source, id, year, title, stitle:, stype:)`，
   参数与搜索页完全一致。
5. **状态**：进行中显示「正在搜索影片源… 当前源（x/y）」；一旦有卡片就先渲染
   卡片、下面再跟一行「继续搜索中…」（结果是一条条流回来的，不干等整个搜索）；
   0 条显示「暂时没搜到可播放源」；出错或超时显示「影片源搜索未成功」，
   两者都给「换词重搜」（弹输入框改词重搜）。
6. **多片名按钮组**：挂在正文**下方**且常驻——结果到达时列表会自动滚到底，
   按钮就在视野里，点一下换下一部；当前正在展示的那一部按钮变绿底白字并置灰
   （同一部再点一次没有新信息）。
7. **history 隔离**：搜索状态、卡片与片名候选只挂在 `AiChatMessage` 的展示
   字段上，`toHistoryJson()` 不含它们，回喂服务端的 history 完全不受影响。

> 「换词重搜 / 输入片名搜源」对话框的输入控制器由对话框自己的 State 持有
> （`_SourceQueryDialog`）。不能在 `showDialog` 返回后立刻 `dispose`：退场动画
> 期间 TextField 仍会重建并 addListener，会抛「A TextEditingController was
> used after being disposed」。

### 2.9 新增：私人影库浏览入口

MoonTVPlus 的 Web UI 有独立的「私人影库」页面（`/private-library`，标题
「私人影库」，副标题「观看自我收藏的高清视频吧」），客户端此前**完全没有**
对应入口 —— Emby 源只能在聚合搜索里偶然搜到时才打得开。

接口契约（三者都需要登录 Cookie）：

| 接口 | 返回 |
|---|---|
| `GET /api/emby/sources` | `{"sources":[{"key":"net","name":"Hohai公益Emby"}, …]}` |
| `GET /api/emby/views?source=<key>` | `{"success":true,"views":[{"id","name","type"}]}` |
| `GET /api/emby/list?source=<key>&viewId=<id>&page=<n>` | `{"success":true,"list":[{id,title,poster,year,rating,mediaType}]}` |

要点：

- 每页固定 20 条，且响应**没有** total / pageCount 字段，因此只能用
  「本页不足 20 条即为末页」来终止分页。
- `mediaType` 为 `movie` / `tv`，界面上分别显示「电影」/「剧集」徽标；
  `rating` 可能为 `0`（视为无评分，不显示），也可能为小数，两种都要能解析。
- 海报虽通常已是绝对地址，仍统一过一遍 `ApiService.absolutize`。
- 播放复用既有链路：`PlayerScreen(source: 'emby_<key>', id: <itemId>)`
  （见 2.3，`emby_*` 源会被路由到 `/api/emby/detail`）。

入口有两个，且都只在后端**真的配置了** Emby 源时出现（探测
`/api/emby/sources` 非空）：

- 主界面底栏「影库」（第 7 项，索引 6）
- 用户菜单「私人影库」

底栏由 6 项变 7 项后，在 320px 窄屏手机上会 RenderFlex 溢出 20px，
因此手机端底栏改为横向滚动容器：放得下时靠 `minWidth` 撑满并保持
`spaceEvenly` 均分（视觉与改动前一致），放不下时可滚动而不是报错。

### 2.10 新增：音乐视听 / 漫画展馆 / 电子书馆（随 1.6.14 发布）

MoonTVPlus 的 Web UI 在首页右上角放了三个内容入口：🎵 音乐视听（绿）、
📖 漫画展馆（青）、📚 电子书馆（琥珀），分别对应 `/music`、`/manga`、
`/books` 三个页面。客户端此前完全没有对应功能。

#### 入口与可见性探测

入口放在**用户菜单**（与 AI 问片、私人影库同一组），而不是底栏：底栏手机端
已经 7 项靠横向滚动才不溢出，再加 3 项不可行；首页右上角加图标行则会挤占
搜索框。三个入口各自探测后端真实可用性才出现：

| 功能 | 探测接口 | 可用判定 |
|---|---|---|
| 音乐视听 | `GET /api/music/v2/discovery/hot-search?source=kw` | HTTP 200 且 `success != false` |
| 漫画展馆 | `GET /api/manga/sources` | 200 且源列表非空 |
| 电子书馆 | `GET /api/books/sources` | 200 且源列表非空（含纯 OPDS） |

为什么用探测而不是配置开关：`/api/server-config` **不暴露**这三个功能
的启停字段（网页端靠服务端注入 HTML 的 `RUNTIME_CONFIG.MUSIC_ENABLED /
SUWAYOMI_ENABLED / BOOKS_ENABLED`），客户端只能摸实际接口。音乐探测的是
热搜接口而不是配置：上游 LxMusic 服务挂掉时（5xx）入口也隐藏，避免
「配置过但点进去全是报错」。探测结果进程级缓存，用户菜单每次打开不重复
打后端；退出登录时全部重置（见下）。

> 实测补充（2026-10-09）：这三条链路的鉴权由 **middleware** 统一把关
> （对所有未豁免的 `/api/*` 校验新版 Cookie 三件套 + HMAC 签名 + 4 小时
> access token 时效），路由自己那层只是查功能权限。客户端不用额外处理
> ——ApiService 的 401 自动续期重试（§2.2）对它们同样生效。

> 顺手修了一个既有隐患：`EmbyService.resetAvailabilityCache` 此前**从未被
> 调用**——登出 / 换服务器后影库入口的可见性还是旧账号的缓存。现在
> `_handleLogout` 里会重置 Emby + 音乐 + 漫画 + 电子书四个缓存。

#### 音乐视听（LxMusic 数据源）

| 接口 | 用途 |
|---|---|
| `GET /api/music/v2/search?q=&source=&type=&page=&limit=` | 搜歌（source ∈ wy/tx/kw/kg/mg） |
| `POST /api/music/v2/play`（body：`{song, quality, includeUrl}`） | 换稳定流地址 + LRC 歌词（含翻译） |
| `GET /api/music/v2/history` / `POST` 同路径 | 最近播放的读与写 |

要点：

- `play.url` 是相对路径（`/api/music/v2/stream?…`）。**该代理同样走
  middleware 鉴权**——实测不带 Cookie 401、带 Cookie 200（16MB 音频），
  所以 media_kit 打开时要挂 `httpHeaders: {'Cookie': …}`
  （`MusicService.mediaHeaders()`）。
- LRC 解析支持一行多时间标（`[00:12.00][01:30.00]同一句`）与
  `.x/.xx/.xxx` 三种小数精度；歌词面板逐行高亮当前行、原文下叠翻译。
- 播放器由页面持有（new Player / 离开页面即 dispose），与
  video_player_widget 的做法一致。

MVP 范围：搜索（song 类型）+ 播放 + 歌词 + 最近播放。歌单
（`/api/music/v2/playlists`）、发现页（榜单 / 歌单广场）、歌手 / 专辑搜索、
播放进度续播（`playProgressSec`）留到后续版本。

#### 漫画展馆（Suwayomi 数据源）

| 接口 | 用途 |
|---|---|
| `GET /api/manga/sources` | 源列表（displayName 优先于 name） |
| `GET /api/manga/search?q=&sourceId=&page=` | 搜漫画（不传 sourceId 则全源搜） |
| `GET /api/manga/detail?mangaId=&sourceId=&…` | 详情 + 章节列表（后端会用传入的元数据兜底） |
| `GET /api/manga/pages?chapterId=` | 章节页列表（返回**相对**代理路径） |

要点：

- 页面图片统一走 `/api/manga/image?path=…`，**这个接口要登录 Cookie**，
  `CachedNetworkImage` 必须挂 `httpHeaders`，否则全部 401。
- 阅读器竖向连续滚动、按原图比例渲染，上一章 / 下一章在底栏切换；
  章节列表默认倒序（最新章在最上），可切换。

MVP 范围：源选择 + 搜索 + 详情 + 阅读。推荐 / 最新
（`/api/manga/recommend`）、书架（`/api/manga/shelf`）、阅读进度
（`/api/manga/history`）留到后续版本。

#### 电子书馆（OPDS + Legado 双引擎，MVP 只走 Legado）

| 接口 | 用途 |
|---|---|
| `GET /api/books/sources` | 源列表（`type` 为 `opds` / `legado`） |
| `GET /api/books/search?q=&sourceId=` | 搜书（不传 sourceId 则全源搜，会混入 OPDS 结果） |
| `GET /api/books/read/chapters?sourceId=&bookId=` | Legado 章节目录 |
| `GET /api/books/read/chapter?sourceId=&href=` | Legado 章节正文（服务端已清洗为纯文本） |

要点：

- **只有 Legado 源能走文本链路**；纯 OPDS 站点入口照常出现，页面顶部给出
  格式说明而不是静默隐藏。
- **「全部」= 客户端 fan-out**：并发对每个 Legado 源发起单源搜索再合并
  （0~3s/源）。不调服务端聚合接口——实测 63 源（含 3 个慢 OPDS）不带
  sourceId 聚合搜要 **38 秒**；fan-out 既快又天然不会混进读不了的
  OPDS 结果。
- 页面提供源 chips（全部 + 各 Legado 源，超长名省略、横向滚动）：书源
  质量参差（很多导入规则源搜索为空或「不支持搜索」），单源切换能让用户
  快速看出哪个源真的有书。
- 正文里残留的 `<img>` / `<br>` 标签在客户端做最后清理；**全角空格
  （段首缩进）必须保留**，不能当 ASCII 空白 trim 掉。
- 阅读器字号调节是会话级（进程内静态值），不做持久化。

MVP 范围：搜书 + 章节目录 + 文本阅读（字号调节、章节跳转）。OPDS 的
epub / pdf（需要引入渲染依赖）、书架（`/api/books/shelf`）、阅读进度
（`/api/books/history`）、TTS 听书（`/api/books/tts/*`）留到后续版本。

---

## 3. 新增与改动的文件

新增：

| 文件 | 作用 |
|---|---|
| `lib/models/server_config.dart` | `/api/server-config` 模型与后端类型识别（MoonTVPlus vs v100） |
| `lib/models/web_live_source.dart` | 网络直播源与直播流模型 |
| `lib/models/ai_message.dart` | AI 对话消息与 SSE 事件模型（含工具链、压缩摘要、影片源展示字段） |
| `lib/services/backend_service.dart` | 后端能力探测 + access token 自动续期 |
| `lib/services/web_live_service.dart` | 网络直播源获取与流地址解析 |
| `lib/services/ai_service.dart` | AI 问片 SSE 流式客户端 |
| `lib/screens/ai_chat_screen.dart` | AI 问片聊天界面（工具链富展示、history 回喂、影片源直出） |
| `lib/models/emby_models.dart` | 私人影库模型（源 / 分类 / 条目）与分页规则 |
| `lib/services/emby_service.dart` | 私人影库三级接口客户端 |
| `lib/screens/private_library_screen.dart` | 私人影库浏览页（源 → 分类 → 条目 → 播放） |
| `lib/models/music_models.dart` | 音乐模型（歌曲 / 播放信息 / LRC 歌词 / 最近播放） |
| `lib/models/manga_models.dart` | 漫画模型（源 / 搜索项 / 章节 / 页列表） |
| `lib/models/book_models.dart` | 电子书模型（源 / 书目 / 章节 / 正文） |
| `lib/services/music_service.dart` | 音乐 v2 客户端（可用性探测 + 搜歌 + 换流地址 + 历史） |
| `lib/services/manga_service.dart` | 漫画客户端（源 / 搜索 / 详情 / 页列表 + 带Cookie图片头） |
| `lib/services/books_service.dart` | 电子书客户端（源 / 搜索 / Legado 章节与正文） |
| `lib/screens/music_screen.dart` | 音乐视听页（搜索 + 播放 + 歌词 + 最近播放） |
| `lib/screens/manga_screen.dart` | 漫画搜索页（源切换 + 封面网格） |
| `lib/screens/manga_detail_screen.dart` | 漫画详情页（元数据 + 章节列表） |
| `lib/screens/manga_reader_screen.dart` | 漫画阅读器（竖向滚动 + 章节切换） |
| `lib/screens/books_screen.dart` | 电子书搜索页（Legado 过滤 + OPDS 说明） |
| `lib/screens/book_reader_screen.dart` | 电子书阅读器（章节目录 + 正文 + 字号） |
| `test/moontvplus_compat_test.dart` | 适配层回归测试（夹具取自真实响应） |
| `test/ai_chat_stream_test.dart` | AI 问片流式渲染 + 影片源直出回归测试 |
| `test/ai_reply_fixture_test.dart`、`test/fixtures/ai_reply_*.json` | 真实模型回复回放：多片名按钮与搜索词闸门（夹具取自真实 `/api/ai/chat` 响应） |
| `test/emby_private_library_test.dart` | 私人影库模型与分页单元测试 |
| `test/private_library_screen_test.dart` | 私人影库页面渲染测试 |
| `test/bottom_nav_test.dart` | 底栏 7 项窄屏不溢出回归测试 |

改动：

| 文件 | 改动 |
|---|---|
| `lib/services/api_service.dart` | 401 自动续期重试；`checkConnection` 改用 `server-config`；Emby 详情分支；绝对地址辅助方法 |
| `lib/services/user_data_service.dart` | 新增 `saveCookies`（供续期写回） |
| `lib/models/search_result.dart` | 新增 `proxyMode` 字段 |
| `lib/models/search_resource.dart` | 新增 `isSearchable` |
| `lib/models/live_channel.dart` | 新增 `headers` 字段并在 `copyWith` 中保留 |
| `lib/services/live_service.dart` | 并入网络直播源与频道解析 |
| `lib/services/search_service.dart`、`lib/services/sse_search_service.dart` | 本地搜索过滤改用 `isSearchable` |
| `lib/screens/player_screen.dart` | 空剧集回源拉详情；播放地址补全与 `proxyMode` 包装 |
| `lib/screens/live_player_screen.dart` | 透传频道级请求头 |
| `lib/widgets/user_menu.dart` | AI 问片入口 + 私人影库入口 + 音乐 / 漫画 / 电子书入口（均按后端能力探测显示）；登出时重置四个能力缓存 |
| `lib/screens/home_screen.dart` | 探测 Emby 可用性，决定是否加入「影库」页与底栏项 |
| `lib/widgets/main_layout.dart` | 新增可选的「影库」底栏项；手机端底栏改为可横向滚动 |
| `lib/services/version_service.dart` | 更新检查指向本 fork 的 Release |

---

## 4. 验证方式

1. **静态分析**：`dart analyze` 无 error、无 warning。
   与上游同一 commit 的基线对比，未引入任何新的 lint 类别。
   ⚠️ **必须用 `dart analyze`，不要用 `flutter analyze`**：后者走 LSP，在含中文的
   路径（如 `/root/DSH/应用/…`）下会直接崩溃（exit 255）。另外 `dart` 不在默认
   PATH 上，先 `export PATH="/root/DSH/tools/flutter/bin:$PATH"`。
2. **回归测试**：`flutter test`（全部用例），夹具直接取自真实
   MoonTVPlus 响应（server-config、搜索事件、AI SSE、网络直播源、
   Emby 三级接口）。含：
   - `test/moontvplus_compat_test.dart`：适配层协议解析
   - `test/ai_chat_stream_test.dart`：用真实 SSE 事件序列驱动真实
     `AiChatScreen`，断言工具名映射、进度反馈、正文渲染、history 回喂结构，
     以及影片源直出（片名提取单测 + 自动搜并点播、多片名按钮、搜索词闸门、
     输入片名入口、解析失败、12 张上限；`/api/search/ws` 用可控 SSE 响应驱动）
   - `test/ai_reply_fixture_test.dart`：**真实模型回复**回放（夹具见
     `test/fixtures/`，取自真实实例的 `/api/ai/chat` SSE），锁住
     「主推片单写在加粗编号行里」与「剧情描述问句不发搜索」两处真实行为
   - `test/music_manga_books_test.dart`：音乐 / 漫画 / 电子书三件套 ——
     契约形状解析（含脏数据防御）、入口可见性探测的判定边界（5xx / 空源 /
     纯 OPDS）、三个页面的 smoke（最近播放兜底、源 chips、Legado 结果过滤）
   - `test/emby_private_library_test.dart`：私人影库模型与分页规则
   - `test/private_library_screen_test.dart`：用真实形状响应驱动真实
     `PrivateLibraryScreen`，断言标题 / 源选择 / 分类 / 条目 / 徽标
   - `test/bottom_nav_test.dart`：320px 窄屏下 7 项底栏不溢出
3. **接口层实测**：在真实实例上逐一核对
   `/api/server-config`、`/api/emby/{sources,views,list,detail}`、
   `/api/detail`（对照 400）、`/api/auth/refresh`、
   `/api/web-live/{sources,stream,proxy}`、
   `/api/search/resources`、`/api/search/ws`、`/api/ai/chat` 的实际响应。
4. **端到端**：`MOONTVPLUS_E2E=1 MOONTVPLUS_BASE_URL=... MOONTVPLUS_COOKIE=... flutter test test/moontvplus_e2e_test.dart`
   —— 默认跳过，需要在能访问真实后端的机器上显式开启，
   会实际调用 Emby 详情、私人影库三级链路、网络直播解析与 AI 流式对话。

写 widget 测试时本项目踩过的四个坑（都已在 `test/ai_chat_stream_test.dart`
里规避，改测试时注意别改回去）：

- 伪造 HTTP 响应用的是**单订阅** `StreamController`，`await close()` 要等唯一
  订阅者消费完 done 才返回。对**从未被监听**的响应（例如用例没触发影片源搜索、
  `setUp` 里预建的那个实例）调 `await close()` 会永久挂起，表现为整个套件
  第一个用例卡死不退出。因此关闭一律 fire-and-forget。
- `SSESearchService` 有 15 秒超时 `Timer`。widget 测试里页面 `dispose()` 的异步
  清理赶不上测试结束，会触发 `'!timersPending'`。收尾要先让服务端补发
  `{"type":"complete"}` 走同步路径撤掉定时器，再 `pumpWidget(SizedBox())`；
  注意**搜索失败路径不会自动断流**，同样要补 `complete`。
- `PlayerScreen` 依赖 media_kit（本机没装 `libmpv`），在单测里构建不出来。
  `AiChatScreen.sourceResultNavigatorOverride` 是为此留的测试接缝，注入一个
  只记参数的回调来断言跳转参数。
- 从**第二轮**影片源搜索起（点第二个片名按钮换片），要先收掉上一轮的 SSE
  （`stopSearch()` 里一串 await），这些续体挂在真实事件循环上，fake async 里
  只靠 `pump()` 推不动，表现为「点了没反应」。测试里用一次
  `await tester.runAsync(() => Future.delayed(...))` 放行真实 turn 即可；
  生产是真实事件循环，不受影响。

---

## 5. 已知限制

- Emby 源在**本地搜索模式**下不可用（该模式下客户端直连采集接口，
  无法访问 MoonTVPlus 的 Emby 私有接口）。请使用服务器搜索模式。
- AI 问片已适配新协议（`EnableNewMode`）的工具链富展示与 history 回喂
  （见 2.8.2）。影片源直出依赖**片名提取启发式**（见 2.8.3）：回复与用户问句里
  都提不出片名时，会显示「没识别到片名 / 输入片名搜源」而不是拿一整句剧情描述
  去搜 —— 属预期行为而非缺陷（实测这类问句在 73 个采集源上 0 结果、白等 9 秒）。
- 片名提取仍是**启发式**，无法保证覆盖所有模型写法：实测常见的「加粗编号榜单项
  + 书名号补充说明」两种已覆盖，但模型若用纯自然段罗列片名（无书名号、无编号），
  仍会退化为手动输入片名。真实模型回复已固化成 fixture 回归测试
  （`test/ai_reply_fixture_test.dart`），改提取逻辑时以它为准绳。
- 影片源直出卡片封顶 12 张、片名候选封顶 8 个、单轮 15 秒超时；只展示聚合搜索
  能返回的源，不做二次分页或按源筛选。
- 多片名按钮组是**按需搜索**（点哪个搜哪个），不并发发起多次聚合搜索：每轮
  搜索串行十几秒，N 部并发既打满服务端也没人看得过来。
- 超分（Anime4K）、弹幕、观影室、追番订阅、网盘等 MoonTVPlus 专有功能
  本次未纳入适配范围。音乐 / 漫画 / 电子书已适配 MVP（见 2.10），但仍有边界：
  - 电子书只支持 **Legado 文本链路**；OPDS 的 epub / pdf、书架、阅读进度、
    TTS 听书未做（epub / pdf 需要引入渲染依赖，单独评估）。
  - 音乐的歌单 / 发现页 / 歌手专辑搜索 / 播放进度续播未做；
    漫画的书架 / 阅读进度 / 推荐页未做。
  - 三者的入口可见性靠**运行时探测**（`server-config` 不暴露这些开关），
    后端把功能关掉或上游数据源失联后，入口会在下次探测后消失。
