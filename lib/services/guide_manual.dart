import 'dart:convert';
import 'dart:math';

import 'locale_strings.dart';
import 'recall_text_matcher.dart';
import 'settings/guide_settings.dart';

class GuideManualSection {
  const GuideManualSection({
    required this.id,
    required this.title,
    required this.keywords,
    required this.body,
    required this.question,
  });

  final String id;
  final String title;
  final List<String> keywords;
  final String body;
  final String question;

  String get searchableText => '$title\n${keywords.join('、')}\n$body';

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'keywords': keywords,
    'body': body,
    'question': question,
  };
}

/// Holt 內置指南。它是可版本化的產品資料，不與 RP prompt 放在一起。
abstract final class GuideManual {
  static List<GuideManualSection> get sections => <GuideManualSection>[
    GuideManualSection(
      id: 'start',
      title: L.pick(en: 'Starting a chat', zhTW: '開始一段對話', zhCN: '开始一段对话'),
      keywords: L
          .pick(
            en: 'start,create character,character card,new chat,heartbeat',
            zhTW: '開始,建立角色,新增身分,人設卡,新窗口,新對話,心跳',
            zhCN: '开始,建立角色,新增身份,人设卡,新窗口,新对话,心跳',
          )
          .split(','),
      body: L.pick(
        en: 'Create or import a character card first. Select that character on Home, then tap the heartbeat to open a new window. A window keeps the mode, user identity and story line chosen when it was created.',
        zhTW:
            '先建立或匯入一張角色人設卡。在首頁選中角色後，點擊心跳即可開啟新窗口。窗口建立時會固定當下的日常／RP 模式、使用者身分與故事線，之後切換全域模式不會改寫舊窗口。',
        zhCN:
            '先建立或导入一张角色人设卡。在首页选中角色后，点击心跳即可开启新窗口。窗口建立时会固定当下的日常／RP 模式、用户身份与故事线，之后切换全局模式不会改写旧窗口。',
      ),
      question: L.pick(
        en: 'How do I start an RP?',
        zhTW: '怎麼開始一段 RP？',
        zhCN: '怎么开始一段 RP？',
      ),
    ),
    GuideManualSection(
      id: 'modes',
      title: L.pick(
        en: 'Daily and RP modes',
        zhTW: '日常與 RP 模式',
        zhCN: '日常与 RP 模式',
      ),
      keywords: L
          .pick(
            en: 'daily,rp,mode,switch,profile,window',
            zhTW: '日常,RP,模式,切換,全域,單角色,檔案,窗口',
            zhCN: '日常,RP,模式,切换,全局,单角色,档案,窗口',
          )
          .split(','),
      body: L.pick(
        en: 'Daily and RP are separate context lanes. Existing windows never change mode. RP uses its own memories, summaries, timeline, relationships, worldbook and story-line state. The app does not add an RP-writing style prompt; the character card remains in control of roleplay style.',
        zhTW:
            '日常與 RP 是分離的上下文軌道，既有窗口不會被改變模式。RP 使用獨立的記憶、摘要、時間線、人物關係、世界書與故事線狀態。Holt 不會額外注入規定演繹風格的 RP prompt，演繹方式仍由角色卡與你的對話決定。',
        zhCN:
            '日常与 RP 是分离的上下文轨道，已有窗口不会被改变模式。RP 使用独立的记忆、摘要、时间线、人物关系、世界书与故事线状态。Holt 不会额外注入规定演绎风格的 RP prompt，演绎方式仍由角色卡与你的对话决定。',
      ),
      question: L.pick(
        en: 'What is the difference between Daily and RP?',
        zhTW: '日常與 RP 有什麼不同？',
        zhCN: '日常与 RP 有什么不同？',
      ),
    ),
    GuideManualSection(
      id: 'context',
      title: L.pick(
        en: 'Memory and summaries',
        zhTW: '記憶、摘要與時間線',
        zhCN: '记忆、摘要与时间线',
      ),
      keywords: L
          .pick(
            en: 'memory,summary,timeline,recall,tag,context',
            zhTW: '記憶,摘要,時間線,召回,標籤,上下文,待確認,做夢',
            zhCN: '记忆,摘要,时间线,召回,标签,上下文,待确认,做梦',
          )
          .split(','),
      body: L.pick(
        en: 'Memory stores reusable facts; a summary preserves the causal flow of a window or story line; the timeline records dated or ordered events. Older summaries may become tagged recall records while the most recent summaries remain directly available. Suggestions still require the app rules and your review before they become trusted memories.',
        zhTW:
            '記憶保存可重用的事實；摘要保留窗口或故事線的因果脈絡；時間線記錄具有日期或先後順序的事件。較舊摘要可轉為帶召回標籤的索引，近期摘要則直接保留。模型建議仍會受後端規則與你的審核限制，不等於已確認事實。',
        zhCN:
            '记忆保存可重用的事实；摘要保留窗口或故事线的因果脉络；时间线记录具有日期或先后顺序的事件。较旧摘要可转为带召回标签的索引，近期摘要则直接保留。模型建议仍会受后端规则与你的审核限制，不等于已确认事实。',
      ),
      question: L.pick(
        en: 'How do memory, summaries and the timeline work?',
        zhTW: '記憶、摘要和時間線怎麼運作？',
        zhCN: '记忆、摘要和时间线怎么运作？',
      ),
    ),
    GuideManualSection(
      id: 'storylines',
      title: L.pick(en: 'RP story lines', zhTW: 'RP 故事線', zhCN: 'RP 故事线'),
      keywords: L
          .pick(
            en: 'story line,chapter,continue,branch,plot archive',
            zhTW: '故事線,主線,篇章,續寫,分支,劇情檔案,多主線',
            zhCN: '故事线,主线,篇章,续写,分支,剧情档案,多主线',
          )
          .split(','),
      body: L.pick(
        en: 'One character can keep separate RP story lines. Their summaries, memories, timeline, relationships, worldbook and story states are scoped to the selected line. Continue a chapter to stay on the same line; create a new chapter when you want another window without rewriting the older one.',
        zhTW:
            '同一角色可以保有彼此獨立的 RP 故事線。摘要、記憶、時間線、人物關係、世界書與劇情狀態會綁定所選故事線。「繼續篇章」沿用原線；「開啟新篇章」建立新的窗口，不改寫舊窗口。',
        zhCN:
            '同一角色可以保有彼此独立的 RP 故事线。摘要、记忆、时间线、人物关系、世界书与剧情状态会绑定所选故事线。“继续篇章”沿用原线；“开启新篇章”建立新的窗口，不改写旧窗口。',
      ),
      question: L.pick(
        en: 'How do I create or switch story lines?',
        zhTW: '怎麼建立或切換故事線？',
        zhCN: '怎么建立或切换故事线？',
      ),
    ),
    GuideManualSection(
      id: 'backup',
      title: L.pick(
        en: 'Backup and device transfer',
        zhTW: '備份與裝置同步',
        zhCN: '备份与设备同步',
      ),
      keywords: L
          .pick(
            en: 'backup,restore,import,export,wifi,sync,device',
            zhTW: '備份,恢復,匯入,匯出,Wi-Fi,同步,設備,裝置',
            zhCN: '备份,恢复,导入,导出,Wi-Fi,同步,设备,装置',
          )
          .split(','),
      body: L.pick(
        en: 'A full backup includes the database, portable preferences and app-owned media, but excludes API secrets and device-local runtime state. Wi-Fi transfer is a one-time device-to-device action. Before replacing or reinstalling a build, make and verify a backup; never uninstall or clear app data when the goal is an in-place update.',
        zhTW:
            '完整備份包含資料庫、可攜式偏好與 App 管理的媒體，但不包含 API 密鑰與裝置瞬時狀態。Wi-Fi 同步是一次性的雙裝置傳輸。覆蓋版本前應先建立並驗證備份；若目標是保留資料更新，不要解除安裝或清除 App 資料。',
        zhCN:
            '完整备份包含数据库、可携式偏好与 App 管理的媒体，但不包含 API 密钥与设备瞬时状态。Wi-Fi 同步是一次性的双设备传输。覆盖版本前应先建立并验证备份；若目标是保留数据更新，不要卸载或清除 App 数据。',
      ),
      question: L.pick(
        en: 'How do I back up or sync my data?',
        zhTW: '如何備份與同步資料？',
        zhCN: '如何备份与同步数据？',
      ),
    ),
    GuideManualSection(
      id: 'api_usage',
      title: L.pick(en: 'API usage', zhTW: 'API 額度與用量', zhCN: 'API 额度与用量'),
      keywords: L
          .pick(
            en: 'api,key,usage,cost,token,cache,model,provider',
            zhTW: 'API,密鑰,key,額度,用量,費用,token,緩存,快取,模型,來源',
            zhCN: 'API,密钥,key,额度,用量,费用,token,缓存,模型,来源',
          )
          .split(','),
      body: L.pick(
        en: 'Opening a local screen does not use API credit. Sending chat, Guide, summary, memory, worldbook, image or other model requests can consume credit. Holt records request and token data when providers return it, but the provider billing page is authoritative. Cache hits may reduce eligible repeated-prefix costs, but changing the cached prefix can interrupt a hit.',
        zhTW:
            '只打開本地頁面不會消耗 API 額度；送出聊天、嚮導、摘要、記憶、世界書、畫圖或其他模型請求才可能產生消耗。Holt 會記錄來源實際回傳的請求與 Token 資料，但最終費用仍以 API 供應商帳單為準。快取命中可降低符合條件的重複前綴成本；改動快取前綴則可能中斷命中。',
        zhCN:
            '只打开本地页面不会消耗 API 额度；送出聊天、向导、摘要、记忆、世界书、画图或其他模型请求才可能产生消耗。Holt 会记录来源实际返回的请求与 Token 数据，但最终费用仍以 API 供应商账单为准。缓存命中可降低符合条件的重复前缀成本；改动缓存前缀则可能中断命中。',
      ),
      question: L.pick(
        en: 'How does API usage work?',
        zhTW: 'API 額度是怎麼消耗的？',
        zhCN: 'API 额度是怎么消耗的？',
      ),
    ),
    GuideManualSection(
      id: 'window_status',
      title: L.pick(
        en: 'Window model and activity',
        zhTW: '窗口模型與活動',
        zhCN: '窗口模型与活动',
      ),
      keywords: L
          .pick(
            en: 'window status,slider icon,model picker,window tokens,summary count,worldbook count,cache hits,window memories',
            zhTW: '窗口狀態,三條拉桿,滑桿圖標,模型選擇,窗口Token,摘要次數,世界書次數,快取命中,已入庫記憶',
            zhCN: '窗口状态,三条拉杆,滑杆图标,模型选择,窗口Token,摘要次数,世界书次数,缓存命中,已入库记忆',
          )
          .split(','),
      body: L.pick(
        en: 'The model row appears briefly when a chat window opens, then collapses into the three-slider icon at the upper right. Tap it to change the model and inspect this window\'s attributed tokens, summary runs, worldbook runs, cache hits and confirmed memories. Tap the memory count to review, edit or move those memories to the dusty box. Cache hits show “—” when the provider does not return reliable hit data. Holt does not guess historical token or worldbook activity created before window attribution was available.',
        zhTW:
            '進入對話窗口時，模型列會短暫顯示，之後收進右上角的三條滑桿圖標。點擊可切換模型，並查看歸屬於目前窗口的 Token、摘要觸發次數、世界書整理次數、快取命中與已確認入庫記憶。點擊記憶數量可查看、編輯，或把記憶移入積灰的小盒子。來源沒有可靠回傳快取資料時會顯示「—」；在窗口歸屬功能建立以前產生的歷史 Token 與世界書調用不會被猜測補算。',
        zhCN:
            '进入对话窗口时，模型栏会短暂显示，之后收进右上角的三条滑杆图标。点击可切换模型，并查看归属于当前窗口的 Token、摘要触发次数、世界书整理次数、缓存命中与已确认入库记忆。点击记忆数量可查看、编辑，或把记忆移入积灰的小盒子。来源没有可靠返回缓存数据时会显示“—”；在窗口归属功能建立以前产生的历史 Token 与世界书调用不会被猜测补算。',
      ),
      question: L.pick(
        en: 'What does the three-slider icon in a chat window do?',
        zhTW: '對話窗口右上角的三條滑桿是做什麼的？',
        zhCN: '对话窗口右上角的三条滑杆是做什么的？',
      ),
    ),
    GuideManualSection(
      id: 'sidebar_settings',
      title: L.pick(
        en: 'Sidebar settings map',
        zhTW: '側邊欄設定導覽',
        zhCN: '侧边栏设置导览',
      ),
      keywords: L
          .pick(
            en: 'sidebar,settings,models,connections,system behavior,feature modules,usage,swipe',
            zhTW: '側邊欄,設定,模型與連線,系統行為,功能模組開關,用量,左側滑動,入口在哪',
            zhCN: '侧边栏,设置,模型与连接,系统行为,功能模块开关,用量,左侧滑动,入口在哪',
          )
          .split(','),
      body: L.pick(
        en: 'On Home or My, swipe right from the far-left edge to open the sidebar; swipe left or tap the uncovered area to close it. Models & connections contains Chat model and Other functional model settings. The latter holds summary, embedding recall, image, sticker-recognition and search models, plus favorite models. System behavior contains the mutually exclusive Context send limit and Cache hit controls, worldbook auto-organization and web search. Feature module switches opens Behavior / Output, prompt-based modules, chat-avatar visibility and Memory & Role. Usage stays pinned at the bottom. Unrelated expanded groups close when another group opens, so only the controls for the current task remain visible.',
        zhTW:
            '在「首頁」或「我的」從螢幕最左側向右滑即可打開側邊欄；向左滑或點擊右側空白處可收起。「模型與連線」包含聊天模型，以及「其他功能模型設定」；後者集中管理摘要、向量召回、畫圖、表情辨識、搜尋模型與收藏模型。「系統行為」包含互斥的上下文發送限制與緩存命中，以及世界書自動整理和網路搜尋。「功能模組開關」可進入對話行為／輸出格式、提示詞功能模組、頭像顯示、記憶與角色功能。「用量」固定在側邊欄底部。展開一項時，沒有關聯的其他項目會自動收起，只保留目前操作需要的內容。',
        zhCN:
            '在“首页”或“我的”从屏幕最左侧向右滑即可打开侧边栏；向左滑或点击右侧空白处可收起。“模型与连接”包含聊天模型，以及“其他功能模型设置”；后者集中管理摘要、向量召回、画图、表情识别、搜索模型与收藏模型。“系统行为”包含互斥的上下文发送限制与缓存命中，以及世界书自动整理和网络搜索。“功能模块开关”可进入对话行为／输出格式、提示词功能模块、头像显示、记忆与角色功能。“用量”固定在侧边栏底部。展开一项时，没有关联的其他项目会自动收起，只保留当前操作需要的内容。',
      ),
      question: L.pick(
        en: 'Where are the settings in the sidebar?',
        zhTW: '側邊欄裡的設定分別放在哪裡？',
        zhCN: '侧边栏里的设置分别放在哪里？',
      ),
    ),
    GuideManualSection(
      id: 'home_greeting',
      title: L.pick(
        en: 'Model-generated home greeting',
        zhTW: '首頁模型問候語',
        zhCN: '首页模型问候语',
      ),
      keywords: L
          .pick(
            en: 'home greeting,home message,character card message,model output greeting,home marker,tool prompts',
            zhTW: '首頁問候語,首頁留言,角色卡留言,模型輸出問候語,模型問候,工具系統提示詞,開關',
            zhCN: '首页问候语,首页留言,角色卡留言,模型输出问候语,模型问候,工具系统提示词,开关',
          )
          .split(','),
      body: L.pick(
        en: 'Open the left sidebar, then go to Feature module switches → Feature modules (prompt switches) → Model-generated home greeting. This switch independently controls whether the model may write the short greeting shown on the Home character card. Turning off Tool prompts does not turn this greeting off; turning off the greeting stops its instruction and prevents its hidden output marker from being saved or shown.',
        zhTW:
            '從左側邊欄進入「功能模組開關」→「功能模組（提示詞開關）」→「模型輸出問候語」。這個開關只控制模型是否能在首頁角色卡留下短問候語，已與「工具系統提示詞」完全分開；關閉工具提示詞不會連帶關閉問候語。關閉模型輸出問候語後，系統不再注入該指令，也不會保存或顯示模型輸出的隱藏問候標記。',
        zhCN:
            '从左侧边栏进入“功能模块开关”→“功能模块（提示词开关）”→“模型输出问候语”。这个开关只控制模型是否能在首页角色卡留下短问候语，已与“工具系统提示词”完全分开；关闭工具提示词不会连带关闭问候语。关闭模型输出问候语后，系统不再注入该指令，也不会保存或显示模型输出的隐藏问候标记。',
      ),
      question: L.pick(
        en: 'How do I turn off model-generated greetings on Home?',
        zhTW: '怎麼關閉模型寫在首頁的問候語？',
        zhCN: '怎么关闭模型写在首页的问候语？',
      ),
    ),
    GuideManualSection(
      id: 'persona',
      title: L.pick(
        en: 'Brainstorming a character',
        zhTW: '一起研究新人設',
        zhCN: '一起研究新人设',
      ),
      keywords: L
          .pick(
            en: 'persona,character card,brainstorm,roleplay idea,not sure',
            zhTW: '人設,角色卡,劇本,靈感,設定,想法,沒想好,聊聊',
            zhCN: '人设,角色卡,剧本,灵感,设定,想法,没想好,聊聊',
          )
          .split(','),
      body: L.pick(
        en: 'You can brainstorm without an existing card. The Guide may gradually assemble an editable character-card proposal from your conversation. It never creates or overwrites a formal character until you review and confirm the proposal.',
        zhTW:
            '你可以在沒有既有人設卡的情況下先聊想法。嚮導會從對話逐步整理一份可編輯的人設卡提案；在你檢查並確認之前，不會自動建立角色，也不會覆蓋既有角色卡。',
        zhCN:
            '你可以在没有既有人设卡的情况下先聊想法。向导会从对话逐步整理一份可编辑的人设卡提案；在你检查并确认之前，不会自动建立角色，也不会覆盖已有角色卡。',
      ),
      question: L.pick(
        en: "I don't have an idea yet. Can we talk first?",
        zhTW: '我還沒想好，先聊聊',
        zhCN: '我还没想好，先聊聊',
      ),
    ),
    GuideManualSection(
      id: 'api_setup',
      title: L.pick(
        en: 'API sources and models',
        zhTW: 'API 來源與模型',
        zhCN: 'API 来源与模型',
      ),
      keywords: L
          .pick(
            en: 'api setup,provider,model id,favorite model,advanced settings,thinking',
            zhTW: 'API設定,來源,模型ID,收藏模型,高級設定,Thinking,金鑰',
            zhCN: 'API设置,来源,模型ID,收藏模型,高级设置,Thinking,密钥',
          )
          .split(','),
      body: L.pick(
        en: 'Choose a provider, save its credentials, then select or enter a model ID. Favorite models keep their provider identity so the same model name can exist under different routes. Advanced settings hold summary, embedding, web-search and provider-specific options. API secrets are kept in secure device storage and are deliberately excluded from portable backups.',
        zhTW:
            '先選擇來源並保存憑證，再拉取列表或直接填入模型 ID。收藏模型會連同來源一起保存，因此相同模型名可存在於不同渠道。高級設定收納摘要模型、向量模型、網路搜尋與來源專屬選項。API 密鑰存放於裝置安全儲存區，刻意不進入可攜式備份。',
        zhCN:
            '先选择来源并保存凭证，再拉取列表或直接填入模型 ID。收藏模型会连同来源一起保存，因此相同模型名可存在于不同渠道。高级设置收纳摘要模型、向量模型、网络搜索与来源专属选项。API 密钥存放于设备安全存储区，刻意不进入可携式备份。',
      ),
      question: L.pick(
        en: 'How do I configure an API model?',
        zhTW: 'API 模型要怎麼設定？',
        zhCN: 'API 模型要怎么设置？',
      ),
    ),
    GuideManualSection(
      id: 'cache_context',
      title: L.pick(
        en: 'Cache and context limits',
        zhTW: '快取與上下文限制',
        zhCN: '缓存与上下文限制',
      ),
      keywords: L
          .pick(
            en: 'prompt cache,cache hit,context limit,summary trigger,tokens',
            zhTW: '緩存命中,快取命中,上下文限制,專用摘要,摘要觸發,token門檻',
            zhCN: '缓存命中,上下文限制,专用摘要,摘要触发,token门槛',
          )
          .split(','),
      body: L.pick(
        en: 'Use Cache hit when the selected provider route supports prompt caching and the chat repeatedly sends a long, stable prefix. Holt recognizes eligible routes from both provider and model, including supported Claude routes, direct Gemini routes and providers with verified automatic caching; the current-window recommendation is safer than judging by a model name alone. Use Context send limit for Inkling, local models, routes without verifiable cache support, or when you prefer to cap the number of recent messages sent. The two modes are mutually exclusive. Enabling either mode also enables its dedicated summary when a summary model is configured; without one, summary stays off. Changing the model, Thinking state or stable prompt settings may create a new cache prefix, and provider billing remains authoritative.',
        zhTW:
            '當所選來源路由支援提示詞快取，而且對話會反覆送出較長、穩定的前綴時，適合使用「緩存命中」。Holt 會同時依來源與模型判斷，包含受支援的 Claude 路由、Gemini 直連路由與已確認具有自動快取的來源；因此應優先看窗口內對目前模型顯示的建議，不要只憑模型名稱判斷。Inkling、本地模型、無法驗證快取能力的中轉路由，或希望直接限制近期消息發送條數時，適合使用「上下文發送限制」。兩種模式互斥；開啟任一模式時，若已選摘要模型會同步開啟對應專用摘要，沒有摘要模型則維持關閉。切換模型、Thinking 狀態或穩定提示設定可能產生新的快取前綴，實際計費仍以來源帳單為準。',
        zhCN:
            '当所选来源路由支持提示词缓存，而且对话会反复送出较长、稳定的前缀时，适合使用“缓存命中”。Holt 会同时依来源与模型判断，包含受支持的 Claude 路由、Gemini 直连路由与已确认具有自动缓存的来源；因此应优先看窗口内对当前模型显示的建议，不要只凭模型名称判断。Inkling、本地模型、无法验证缓存能力的中转路由，或希望直接限制近期消息发送条数时，适合使用“上下文发送限制”。两种模式互斥；开启任一模式时，若已选摘要模型会同步开启对应专用摘要，没有摘要模型则维持关闭。切换模型、Thinking 状态或稳定提示设置可能产生新的缓存前缀，实际计费仍以来源账单为准。',
      ),
      question: L.pick(
        en: 'Which models should use cache, and when should I use a context limit?',
        zhTW: '哪些模型適合緩存命中？什麼時候改用上下文限制？',
        zhCN: '哪些模型适合缓存命中？什么时候改用上下文限制？',
      ),
    ),
    GuideManualSection(
      id: 'user_identity',
      title: L.pick(
        en: 'Your identities and bindings',
        zhTW: '你的身分與綁定',
        zhCN: '你的身份与绑定',
      ),
      keywords: L
          .pick(
            en: 'my identity,user persona,profile,binding,daily profile,rp profile',
            zhTW: '我的身分,使用者角色,檔案,綁定角色,日常資料,RP資料,代詞,自我介紹',
            zhCN: '我的身份,用户角色,档案,绑定角色,日常资料,RP资料,代词,自我介绍',
          )
          .split(','),
      body: L.pick(
        en: 'User identities are separate from bot character cards. A profile can hold nickname, pronouns and an introduction, with separate Daily/RP file content where configured. The bound character is shared by both modes. A new window freezes the selected identity snapshot so later edits do not silently rewrite older dialogue.',
        zhTW:
            '使用者身分與對方角色卡是兩套資料。檔案可保存暱稱、稱謂／代詞與自我介紹，並分別保存日常／RP 內容；綁定角色則由兩種模式共用。新窗口會凍結建立當下的身分快照，後續修改不會偷偷改寫舊對話。',
        zhCN:
            '用户身份与对方角色卡是两套资料。档案可保存昵称、称谓／代词与自我介绍，并分别保存日常／RP 内容；绑定角色则由两种模式共用。新窗口会冻结建立当下的身份快照，后续修改不会偷偷改写旧对话。',
      ),
      question: L.pick(
        en: 'How do my identities and character bindings work?',
        zhTW: '我的身分和角色綁定怎麼運作？',
        zhCN: '我的身份和角色绑定怎么运作？',
      ),
    ),
    GuideManualSection(
      id: 'rp_archive',
      title: L.pick(en: 'RP story data', zhTW: 'RP 劇情資料', zhCN: 'RP 剧情资料'),
      keywords: L
          .pick(
            en: 'worldbook,relationships,story state,characters,lore,knowledge boundary',
            zhTW: '世界書,人物關係,劇情狀態,角色人物,世界觀,知情邊界,身分表',
            zhCN: '世界书,人物关系,剧情状态,角色人物,世界观,知情边界,身份表',
          )
          .split(','),
      body: L.pick(
        en: 'In RP, the worldbook stores durable lore and rules; relationships store pair-specific history and reasons for change; story states keep the latest scene, promises, identity use, knowledge boundaries, body state, plot state and important items. These records are scoped to the current story line and can be inspected from RP story-data entries. They support continuity but never replace the original character card.',
        zhTW:
            'RP 中，世界書保存耐久世界觀與規則；人物關係逐對記錄關係歷史及變化原因；劇情狀態保存當前場景、承諾、身分使用、知情邊界、身體狀態、劇情狀態與重要物品。這些資料綁定目前故事線，可從 RP 劇情資料入口查看；它們用來維持連貫，不會覆蓋原始角色卡。',
        zhCN:
            'RP 中，世界书保存耐久世界观与规则；人物关系逐对记录关系历史及变化原因；剧情状态保存当前场景、承诺、身份使用、知情边界、身体状态、剧情状态与重要物品。这些资料绑定当前故事线，可从 RP 剧情资料入口查看；它们用来维持连贯，不会覆盖原始角色卡。',
      ),
      question: L.pick(
        en: 'What are the worldbook and relationships for?',
        zhTW: '世界書和人物關係分別做什麼？',
        zhCN: '世界书和人物关系分别做什么？',
      ),
    ),
    GuideManualSection(
      id: 'appearance',
      title: L.pick(en: 'Themes and backgrounds', zhTW: '主題與背景', zhCN: '主题与背景'),
      keywords: L
          .pick(
            en: 'theme studio,background,preset,bubble,color,font,bind character,blur',
            zhTW: '主題工坊,背景,預設,氣泡,顏色,字體,綁定角色,模糊度',
            zhCN: '主题工坊,背景,预设,气泡,颜色,字体,绑定角色,模糊度',
          )
          .split(','),
      body: L.pick(
        en: 'Theme Studio controls theme colors, fonts, bubbles, effects and saved image-background presets. Manual bubble or text choices take priority over automatic colors inferred from a background. Background bindings can select a saved preset for the intended character or story context; unbound content follows the currently selected theme.',
        zhTW:
            '主題工坊管理主題色、字體、氣泡、特效與已保存的圖片背景方案。使用者手動指定的氣泡或文字顏色優先於背景自適應結果。背景綁定可讓指定角色或故事情境使用某套預設；沒有綁定時則沿用目前選中的主題。',
        zhCN:
            '主题工坊管理主题色、字体、气泡、特效与已保存的图片背景方案。用户手动指定的气泡或文字颜色优先于背景自适应结果。背景绑定可让指定角色或故事情境使用某套预设；没有绑定时则沿用目前选中的主题。',
      ),
      question: L.pick(
        en: 'How do background presets and bindings work?',
        zhTW: '背景方案和綁定怎麼使用？',
        zhCN: '背景方案和绑定怎么使用？',
      ),
    ),
    GuideManualSection(
      id: 'errors',
      title: L.pick(en: 'Errors and diagnostics', zhTW: '錯誤與診斷', zhCN: '错误与诊断'),
      keywords: L
          .pick(
            en: 'error,diagnostic card,401,403,429,quota,retry,raw log,feedback,contact,email,report',
            zhTW: '報錯,錯誤卡,診斷卡,401,403,429,額度,重試,原始日誌,回饋,回報,聯繫,郵件',
            zhCN: '报错,错误卡,诊断卡,401,403,429,额度,重试,原始日志,反馈,回报,联系,邮件',
          )
          .split(','),
      body: L.pick(
        en: 'Request failures appear in place as persistent diagnostic cards rather than temporary blocking notices. The card gives a plain-language conclusion, lets you retry in place and keeps the raw provider log folded for copying. Authentication errors usually point to credentials or route restrictions; 429 may mean rate limiting or exhausted quota; 5xx means an upstream service problem.',
        zhTW:
            '請求失敗會在原本回覆位置留下可持續查看的診斷卡，而不是用遮擋操作的短暫提示。卡片提供人話結論、原地重試與可展開複製的供應商原始日誌。401／403 通常涉及憑證、限額或節點限制；429 可能是請求過頻或額度用盡；5xx 多為上游服務故障。若要提供回饋或回報錯誤，請寄信到 wrenmyco@proton.me；嚮導可根據最近五條已去除私人內容的本機報錯記錄協助起草，寄出前請先檢查。',
        zhCN:
            '请求失败会在原本回复位置留下可持续查看的诊断卡，而不是用遮挡操作的短暂提示。卡片提供易懂结论、原地重试与可展开复制的供应商原始日志。401／403 通常涉及凭证、限额或节点限制；429 可能是请求过频或额度用尽；5xx 多为上游服务故障。若要提供反馈或报告错误，请发送邮件至 wrenmyco@proton.me；向导可根据最近五条已去除私人内容的本机报错记录协助起草，发送前请先检查。',
      ),
      question: L.pick(
        en: 'What should I do when an API request fails?',
        zhTW: 'API 請求失敗時怎麼處理？',
        zhCN: 'API 请求失败时怎么处理？',
      ),
    ),
  ];

  static List<String> get popularQuestions => sections
      .take(6)
      .map((section) => section.question)
      .toList(growable: false);

  static List<GuideManualSection> retrieve(String query, {int limit = 3}) {
    final terms = RecallTextMatcher.relevanceTerms(query, maxTerms: 64);
    if (terms.isEmpty) return const <GuideManualSection>[];
    final scored = <({GuideManualSection section, int score})>[];
    for (final section in sections) {
      var score = 0;
      for (final term in terms) {
        final match = RecallTextMatcher.bestKeywordMatch(
          section.searchableText,
          term,
        );
        if (match != null) score += match.score;
      }
      if (score > 0) scored.add((section: section, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).map((value) => value.section).toList();
  }

  static List<String> followUpsFor(
    List<GuideManualSection> matched, {
    int limit = 3,
    String exclude = '',
    int? seed,
  }) {
    final used = matched.map((section) => section.id).toSet();
    final related = [...matched]..shuffle(Random(seed));
    final remaining =
        sections
            .where((section) => !used.contains(section.id))
            .toList(growable: false)
          ..shuffle(Random(seed == null ? null : seed + 1));
    return <GuideManualSection>[...related, ...remaining]
        .map((section) => section.question)
        .where((question) => question.trim() != exclude.trim())
        .toSet()
        .take(limit)
        .toList(growable: false);
  }

  static String snapshot() => jsonEncode(<String, Object?>{
    'version': GuideSettings.bundledManualVersion,
    'locale': L.locale,
    'sections': sections.map((section) => section.toJson()).toList(),
  });

  static Future<void> ensureSnapshotPersisted() =>
      GuideSettings.refreshBundledManual(snapshot());
}
