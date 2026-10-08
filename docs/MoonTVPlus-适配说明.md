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

---

## 3. 新增与改动的文件

新增：

| 文件 | 作用 |
|---|---|
| `lib/models/server_config.dart` | `/api/server-config` 模型与后端类型识别（MoonTVPlus vs v100） |
| `lib/models/web_live_source.dart` | 网络直播源与直播流模型 |
| `lib/models/ai_message.dart` | AI 对话消息与 SSE 事件模型 |
| `lib/services/backend_service.dart` | 后端能力探测 + access token 自动续期 |
| `lib/services/web_live_service.dart` | 网络直播源获取与流地址解析 |
| `lib/services/ai_service.dart` | AI 问片 SSE 流式客户端 |
| `lib/screens/ai_chat_screen.dart` | AI 问片聊天界面 |
| `lib/models/emby_models.dart` | 私人影库模型（源 / 分类 / 条目）与分页规则 |
| `lib/services/emby_service.dart` | 私人影库三级接口客户端 |
| `lib/screens/private_library_screen.dart` | 私人影库浏览页（源 → 分类 → 条目 → 播放） |
| `test/moontvplus_compat_test.dart` | 适配层回归测试（夹具取自真实响应） |
| `test/ai_chat_stream_test.dart` | AI 问片流式渲染回归测试 |
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
| `lib/widgets/user_menu.dart` | AI 问片入口 + 私人影库入口（均按后端能力显示） |
| `lib/screens/home_screen.dart` | 探测 Emby 可用性，决定是否加入「影库」页与底栏项 |
| `lib/widgets/main_layout.dart` | 新增可选的「影库」底栏项；手机端底栏改为可横向滚动 |
| `lib/services/version_service.dart` | 更新检查指向本 fork 的 Release |

---

## 4. 验证方式

1. **静态分析**：`flutter analyze` 无 error、无 warning。
   与上游同一 commit 的基线对比，未引入任何新的 lint 类别。
2. **回归测试**：`flutter test`（全部用例），夹具直接取自真实
   MoonTVPlus 响应（server-config、搜索事件、AI SSE、网络直播源、
   Emby 三级接口）。含：
   - `test/moontvplus_compat_test.dart`：适配层协议解析
   - `test/ai_chat_stream_test.dart`：用真实 SSE 事件序列驱动真实
     `AiChatScreen`，断言工具名映射、进度反馈与正文渲染
   - `test/emby_private_library_test.dart`：私人影库模型与分页规则
   - `test/private_library_screen_test.dart`：用真实形状响应驱动真实
     `PrivateLibraryScreen`，断言标题 / 源选择 / 分类 / 条目 / 徽标
   - `test/bottom_nav_test.dart`：320px 窄屏下 7 项底栏不溢出
3. **接口层实测**：在真实实例上逐一核对
   `/api/server-config`、`/api/emby/{sources,views,list,detail}`、
   `/api/detail`（对照 400）、`/api/auth/refresh`、
   `/api/web-live/{sources,stream,proxy}`、
   `/api/search/resources`、`/api/ai/chat` 的实际响应。
4. **端到端**：`MOONTVPLUS_E2E=1 MOONTVPLUS_BASE_URL=... MOONTVPLUS_COOKIE=... flutter test test/moontvplus_e2e_test.dart`
   —— 默认跳过，需要在能访问真实后端的机器上显式开启，
   会实际调用 Emby 详情、私人影库三级链路、网络直播解析与 AI 流式对话。

---

## 5. 已知限制

- Emby 源在**本地搜索模式**下不可用（该模式下客户端直连采集接口，
  无法访问 MoonTVPlus 的 Emby 私有接口）。请使用服务器搜索模式。
- AI 问片的「工具调用状态」目前以状态提示呈现；
  MoonTVPlus 新协议模式（`EnableNewMode`）下的工具结果富展示未做适配。
- 超分（Anime4K）、弹幕、观影室、追番订阅、网盘、书籍、漫画、音乐等
  MoonTVPlus 专有功能本次未纳入适配范围。
