import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

class L {
  static String _locale = 'en';
  static String get locale => _locale;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('app_locale');
    if (saved != null && localeNames.containsKey(saved)) {
      _locale = saved;
      return;
    }

    final deviceLocale = PlatformDispatcher.instance.locale;
    if (deviceLocale.languageCode.toLowerCase() == 'zh') {
      final region = deviceLocale.countryCode?.toUpperCase();
      final script = deviceLocale.scriptCode?.toLowerCase();
      _locale = (region == 'CN' || region == 'SG' || script == 'hans')
          ? 'zh_CN'
          : 'zh_TW';
    } else {
      _locale = 'en';
    }
  }

  static Future<void> setLocale(String v) async {
    _locale = v;
    final p = await SharedPreferences.getInstance();
    await p.setString('app_locale', v);
  }

  static const localeNames = <String, String>{
    'zh_TW': '繁體中文',
    'zh_CN': '简体中文',
    'en': 'English',
  };

  static String get(String key) {
    final table = _strings[key];
    if (table == null) return key;
    return table[_locale] ?? table['zh_TW'] ?? key;
  }

  static String fmt(String key, List<dynamic> args) {
    var s = get(key);
    for (int i = 0; i < args.length; i++) {
      s = s.replaceFirst('{$i}', args[i].toString());
    }
    return s;
  }

  /// 三語即時文案。既有頁面仍有不少無法直接搬進字典的動態字串；
  /// zhCn 未明列時，只轉換專案 UI 實際使用到的繁體字，不碰使用者內容。
  static String pick({required String en, required String zhTW, String? zhCN}) {
    return switch (_locale) {
      'en' => en,
      'zh_CN' => zhCN ?? _toSimplifiedUi(zhTW),
      _ => zhTW,
    };
  }

  static final Map<int, int> _traditionalToSimplified = _buildUiCharMap();

  static Map<int, int> _buildUiCharMap() {
    const pairs =
        '丟丢並并乾干亂乱佇伫佈布佔占併并來来係系個个們们側侧偵侦偽伪備备傳传傾倾僅仅價价優优儲储兇凶內内兩两冊册冪幂凍冻別别刪删則则剛刚剝剥創创劃划動动務务勞劳勢势勵励匯汇區区卻却參参問问啟启喚唤單单嗎吗嘗尝噠哒嚴严圍围圓圆圖图團团執执場场塊块壓压夠够實实審审寫写寬宽將将專专尋寻對对導导層层屬属島岛帳帐帶带幀帧幣币幹干幾几庫库廠厂張张強强彈弹後后徑径從从復复徹彻恆恒愜惬態态慣惯慾欲憶忆應应懶懒懸悬戲戏戶户掃扫掛挂採采換换搖摇搶抢撈捞撐撑撥拨擇择擊击據据擠挤擬拟擴扩擷撷擺摆擾扰敗败敘叙數数斷断於于時时暈晕暢畅暫暂暱昵曉晓會会條条棄弃極极構构樂乐標标樞枢樣样機机橫横檔档檢检檻槛欄栏權权歷历歸归殘残殼壳氣气決决沒没洩泄淨净淺浅減减測测湊凑湧涌準准溫温滯滞滾滚滿满漣涟漲涨漸渐潔洁潛潜潤润澤泽濃浓濾滤瀏浏為为無无熱热燈灯燒烧爍烁爾尔牽牵狀状獎奖獨独獲获獺獭現现環环產产畫画異异當当疊叠癮瘾發发監监盤盘確确碼码礎础礙碍禮礼種种稱称積积穩稳競竞筆笔箋笺節节範范簡简籤签紀纪約约紅红紋纹納纳純纯級级細细紹绍終终組组結结絕绝絡络給给統统絲丝綁绑經经綠绿維维網网綴缀緊紧緒绪線线緣缘編编緩缓縫缝縮缩總总織织繞绕繪绘繼继續续義义習习聯联聲声聽听脈脉脹胀腦脑腳脚膠胶與与舊旧茲兹葉叶著着蓋盖薦荐藍蓝處处號号螢萤衝冲補补裝装裡里製制複复見见規规視视親亲覺觉覽览觀观觸触訂订計计訊讯記记設设許许訴诉診诊註注評评詞词詢询試试話话該该詳详誌志認认語语誤误說说誰谁調调請请諧谐諾诺謂谓謔谑講讲證证識识議议護护讀读變变讓让豎竖貝贝負负貫贯貴贵買买費费貼贴資资質质賴赖購购贈赠跡迹蹤踪躍跃軌轨軟软軸轴較较載载輕轻輪轮輯辑輸输輻辐轉转迴回這这連连週周進进遊游運运過过達达遞递遠远適适遲迟選选還还邊边邏逻鄰邻釋释釘钉針针鈕钮鈴铃銀银銜衔銳锐銷销鋪铺錄录錢钱錨锚錯错鍵键鎖锁鏈链鏡镜鐘钟鑰钥長长門门閃闪閉闭開开閒闲間间關关陰阴階阶際际隨随隱隐隻只雙双離离雲云電电靈灵靜静韌韧響响頁页頂顶項项順顺須须預预頓顿頭头頻频題题額额顏颜願愿類类顯显風风飄飘飛飞飽饱飾饰餘余餵喂饋馈駐驻驅驱驗验體体髮发鬆松鳴鸣麥麦麼么點点齊齐齒齿';
    final runes = pairs.runes.toList(growable: false);
    final result = <int, int>{};
    for (var i = 0; i + 1 < runes.length; i += 2) {
      result[runes[i]] = runes[i + 1];
    }
    return result;
  }

  static String _toSimplifiedUi(String input) => String.fromCharCodes(
    input.runes.map((rune) => _traditionalToSimplified[rune] ?? rune),
  );

  static const Map<String, Map<String, String>> _strings = {
    'nav_usage': {'zh_TW': '用量', 'zh_CN': '用量', 'en': 'Usage'},
    'nav_memory': {'zh_TW': '記憶', 'zh_CN': '记忆', 'en': 'Memory'},
    'nav_chat': {'zh_TW': '首頁', 'zh_CN': '首页', 'en': 'Home'},
    'nav_settings': {'zh_TW': '設定', 'zh_CN': '设定', 'en': 'Settings'},
    'nav_character': {'zh_TW': '角色', 'zh_CN': '角色', 'en': 'Chars'},
    'nav_me': {'zh_TW': '我的', 'zh_CN': '我的', 'en': 'Me'},
    'me_character_card': {'zh_TW': '人設卡', 'zh_CN': '人设卡', 'en': 'Characters'},
    'me_user_profile': {'zh_TW': '用戶檔案', 'zh_CN': '用户档案', 'en': 'Profile'},
    'me_sticker': {'zh_TW': '我的表情庫', 'zh_CN': '我的表情库', 'en': 'My Stickers'},
    'me_theme': {'zh_TW': '主題工坊', 'zh_CN': '主题工坊', 'en': 'Theme Studio'},
    'me_theme_sub': {
      'zh_TW': '主題色 · 字體 · 外觀',
      'zh_CN': '主题色 · 字体 · 外观',
      'en': 'Colors · Fonts · Appearance',
    },
    'chat_empty': {'zh_TW': '說點什麼吧', 'zh_CN': '说点什么吧', 'en': 'Say something'},
    'chat_edit': {'zh_TW': '編輯消息', 'zh_CN': '编辑消息', 'en': 'Edit Message'},
    'chat_save': {'zh_TW': '保存', 'zh_CN': '保存', 'en': 'Save'},
    'chat_resend': {'zh_TW': '重新發送', 'zh_CN': '重新发送', 'en': 'Resend'},
    'chat_cancel': {'zh_TW': '取消', 'zh_CN': '取消', 'en': 'Cancel'},
    'chat_copy': {'zh_TW': '複製', 'zh_CN': '复制', 'en': 'Copy'},
    'chat_copied': {'zh_TW': '已複製', 'zh_CN': '已复制', 'en': 'Copied'},
    'chat_image_hint': {
      'zh_TW': '已選擇圖片，輸入文字後一起發送',
      'zh_CN': '已选择图片，输入文字后一起发送',
      'en': 'Image selected, type to send together',
    },
    'chat_thinking': {'zh_TW': '思考過程', 'zh_CN': '思考过程', 'en': 'Thinking'},
    'chat_memory_noted': {
      'zh_TW': '📝 已記下',
      'zh_CN': '📝 已记下',
      'en': '📝 Noted',
    },
    'chat_error': {'zh_TW': '出錯了', 'zh_CN': '出错了', 'en': 'Error'},
    'chat_swipe_delete': {
      'zh_TW': '← 滑動刪除',
      'zh_CN': '← 滑动删除',
      'en': '← Swipe to delete',
    },
    'chat_new': {'zh_TW': '新對話', 'zh_CN': '新对话', 'en': 'New Chat'},
    'chat_placeholder': {
      'zh_TW': '想說什麼都可以。',
      'zh_CN': '想说什么都可以。',
      'en': 'Say anything.',
    },
    'chat_api_star_hint': {
      'zh_TW': '先去 API 設定裡星標幾個常用模型',
      'zh_CN': '先去 API 设定里星标几个常用模型',
      'en': 'Star some models in API Settings first',
    },
    'chat_title_edit': {'zh_TW': '對話標題', 'zh_CN': '对话标题', 'en': 'Chat Title'},
    'call_hold': {
      'zh_TW': '按住麥克風說話',
      'zh_CN': '按住麦克风说话',
      'en': 'Hold mic to talk',
    },
    'call_listening': {
      'zh_TW': '正在聽……',
      'zh_CN': '正在听……',
      'en': 'Listening...',
    },
    'call_thinking': {'zh_TW': '思考中……', 'zh_CN': '思考中……', 'en': 'Thinking...'},
    'call_speaking': {'zh_TW': '說話中……', 'zh_CN': '说话中……', 'en': 'Speaking...'},
    'call_continue': {
      'zh_TW': '按住麥克風繼續',
      'zh_CN': '按住麦克风继续',
      'en': 'Hold mic to continue',
    },
    'call_no_hear': {
      'zh_TW': '沒有聽到，再試一次',
      'zh_CN': '没有听到，再试一次',
      'en': 'Didn\'t catch that',
    },
    'call_stt_error': {
      'zh_TW': '語音識別錯誤，再試一次',
      'zh_CN': '语音识别错误，再试一次',
      'en': 'Speech error, try again',
    },
    'call_stt_unavailable': {
      'zh_TW': '語音識別不可用',
      'zh_CN': '语音识别不可用',
      'en': 'Speech unavailable',
    },
    'call_stt_init_fail': {
      'zh_TW': '語音識別初始化失敗',
      'zh_CN': '语音识别初始化失败',
      'en': 'Speech init failed',
    },
    'call_error': {
      'zh_TW': '出錯了，再試一次',
      'zh_CN': '出错了，再试一次',
      'en': 'Error, try again',
    },
    'call_signal_lost': {
      'zh_TW': '對方的信號不佳，請稍後再撥',
      'zh_CN': '对方的信号不佳，请稍后再拨',
      'en': 'Poor signal. Please call again later',
    },
    'call_log': {'zh_TW': '對話記錄', 'zh_CN': '对话记录', 'en': 'Call Log'},
    'call_incoming': {
      'zh_TW': '來電……',
      'zh_CN': '来电……',
      'en': 'Incoming call...',
    },
    'call_accept': {'zh_TW': '接聽', 'zh_CN': '接听', 'en': 'Answer'},
    'call_hangup': {'zh_TW': '掛斷', 'zh_CN': '挂断', 'en': 'Hang up'},
    'call_mute': {'zh_TW': '靜音', 'zh_CN': '静音', 'en': 'Mute'},
    'call_unmute': {'zh_TW': '取消靜音', 'zh_CN': '取消静音', 'en': 'Unmute'},
    'call_muted': {'zh_TW': '已靜音', 'zh_CN': '已静音', 'en': 'Muted'},
    'call_mode_hold': {'zh_TW': '按住說話', 'zh_CN': '按住说话', 'en': 'Hold to talk'},
    'call_mode_auto': {'zh_TW': '自動聆聽', 'zh_CN': '自动聆听', 'en': 'Auto listen'},
    'call_auto_hint': {
      'zh_TW': '說完停頓會自動發送',
      'zh_CN': '说完停顿会自动发送',
      'en': 'Auto-sends when you pause',
    },
    'call_tap_interrupt': {
      'zh_TW': '點頭像可打斷',
      'zh_CN': '点头像可打断',
      'en': 'Tap avatar to interrupt',
    },
    'settings_ringtone': {'zh_TW': '來電鈴聲', 'zh_CN': '来电铃声', 'en': 'Ringtone'},
    'settings_header': {'zh_TW': '設定', 'zh_CN': '设定', 'en': 'Settings'},
    'settings_memory': {
      'zh_TW': '窗口摘要',
      'zh_CN': '窗口摘要',
      'en': 'Window Summary',
    },
    'settings_memory_on': {
      'zh_TW': '啟用窗口摘要',
      'zh_CN': '启用窗口摘要',
      'en': 'Enable Window Summary',
    },
    'settings_memory_off_hint': {
      'zh_TW': '關閉後不會壓縮長對話上下文',
      'zh_CN': '关闭后不会压缩长对话上下文',
      'en': 'Long chats will not be compressed when off',
    },
    'settings_summary_model': {
      'zh_TW': '窗口摘要模型（選便宜的）',
      'zh_CN': '窗口摘要模型（选便宜的）',
      'en': 'Window summary model (cheap)',
    },
    'settings_thinking': {
      'zh_TW': '思考鏈',
      'zh_CN': '思考链',
      'en': 'Thinking Chain',
    },
    'settings_thinking_desc': {
      'zh_TW': '讓 AI 展示思考過程',
      'zh_CN': '让 AI 展示思考过程',
      'en': 'Show AI thinking',
    },
    'settings_thinking_hint': {
      'zh_TW': '回覆前用 <think> 標籤輸出內心思考',
      'zh_CN': '回复前用 <think> 标签输出内心思考',
      'en': 'Output thinking in <think> tags',
    },
    'settings_split': {'zh_TW': '多氣泡回覆', 'zh_CN': '多气泡回复', 'en': 'Split Reply'},
    'settings_split_desc': {
      'zh_TW': 'AI 回覆按段落拆成多個氣泡',
      'zh_CN': 'AI 回复按段落拆成多个气泡',
      'en': 'Split into paragraph bubbles',
    },
    'settings_split_hint': {
      'zh_TW': '開啟後建議關閉思考鏈',
      'zh_CN': '开启后建议关闭思考链',
      'en': 'Consider turning off Thinking Chain',
    },
    'settings_token_save': {
      'zh_TW': '節省 Token',
      'zh_CN': '节省 Token',
      'en': 'Save Tokens',
    },
    'settings_concise': {
      'zh_TW': '精簡對話',
      'zh_CN': '精简对话',
      'en': 'Concise Mode',
    },
    'settings_concise_desc': {
      'zh_TW': '簡單問題幾句話回應，不過度格式化',
      'zh_CN': '简单问题几句话回应，不过度格式化',
      'en': 'Short replies, minimal formatting',
    },
    'settings_concise_hint': {
      'zh_TW': '風格引導，模型自行判斷長短',
      'zh_CN': '风格引导，模型自行判断长短',
      'en': 'Style hint, model decides length',
    },
    'settings_freeform': {
      'zh_TW': '自由發揮',
      'zh_CN': '自由发挥',
      'en': 'Guided Length',
    },
    'settings_freeform_desc': {
      'zh_TW': '建議模型回覆不超過指定行數',
      'zh_CN': '建议模型回复不超过指定行数',
      'en': 'Suggest max reply lines',
    },
    'settings_freeform_hint': {
      'zh_TW': '軟建議，情境需要時仍可展開',
      'zh_CN': '软建议，情境需要时仍可展开',
      'en': 'Soft limit, expands when needed',
    },
    'settings_freeform_lines': {
      'zh_TW': '建議行數',
      'zh_CN': '建议行数',
      'en': 'Max lines',
    },
    'settings_vibration': {'zh_TW': '回覆震動', 'zh_CN': '回复震动', 'en': 'Haptic'},
    'settings_vibration_on': {
      'zh_TW': '回覆完成時輕震動',
      'zh_CN': '回复完成时轻震动',
      'en': 'Vibrate on reply',
    },
    'settings_cache': {
      'zh_TW': '緩存命中',
      'zh_CN': '缓存命中',
      'en': 'Prompt Caching',
    },
    'settings_cache_title': {
      'zh_TW': '緩存命中',
      'zh_CN': '缓存命中',
      'en': 'Prompt Caching',
    },
    'settings_cache_on': {
      'zh_TW': '啟用緩存命中',
      'zh_CN': '启用缓存命中',
      'en': 'Enable Prompt Caching',
    },
    'settings_cache_hint': {
      'zh_TW': 'Claude 系會自動使用可用 TTL；無 1 小時 TTL 不做關窗保活',
      'zh_CN': 'Claude 系会自动使用可用 TTL；无 1 小时 TTL 不做关窗保活',
      'en':
          'Claude-family models use available TTL; no 1h TTL means no close-window keep-alive',
    },
    'settings_context_limit': {
      'zh_TW': '上下文 token 上限',
      'zh_CN': '上下文 token 上限',
      'en': 'Context token limit',
    },
    'settings_context_desc': {
      'zh_TW': '每次發送的上下文 token 上限',
      'zh_CN': '每次发送的上下文 token 上限',
      'en': 'Max context tokens per send',
    },
    'settings_context_hint': {
      'zh_TW': '0 = 不限制',
      'zh_CN': '0 = 不限制',
      'en': '0 = unlimited',
    },
    'settings_language': {'zh_TW': '界面語言', 'zh_CN': '界面语言', 'en': 'Language'},
    'settings_qwen': {
      'zh_TW': '通義千問 直連',
      'zh_CN': '通义千问 直连',
      'en': 'Qwen Direct',
    },
    'settings_sticker_model': {
      'zh_TW': '分析表情包用的模型',
      'zh_CN': '分析表情包用的模型',
      'en': 'Sticker vision model',
    },
    'settings_observe': {
      'zh_TW': '觀察記憶',
      'zh_CN': '观察记忆',
      'en': 'Observe Memory',
    },
    'memory_title': {'zh_TW': '記憶', 'zh_CN': '记忆', 'en': 'Memory'},
    'memory_long': {'zh_TW': '長期記憶', 'zh_CN': '长期记忆', 'en': 'Long-term'},
    'memory_unfinished': {'zh_TW': '未完待續', 'zh_CN': '未完待续', 'en': 'Ongoing'},
    'memory_all': {'zh_TW': '這些我都記得', 'zh_CN': '这些我都记得', 'en': 'I remember'},
    'memory_recording': {'zh_TW': '正在記錄', 'zh_CN': '正在记录', 'en': 'Recording'},
    'memory_archive': {'zh_TW': '積灰小盒子', 'zh_CN': '积灰小盒子', 'en': 'Archive'},
    'memory_archive_hint': {
      'zh_TW': '僅本地保存，不會注入對話',
      'zh_CN': '仅本地保存，不会注入对话',
      'en': 'Local only',
    },
    'memory_clear_all': {'zh_TW': '一鍵清空', 'zh_CN': '一键清空', 'en': 'Clear All'},
    'memory_delete_confirm': {
      'zh_TW': '永久刪除？不可恢復。',
      'zh_CN': '永久删除？不可恢复。',
      'en': 'Delete permanently?',
    },
    'memory_box_empty': {
      'zh_TW': '小盒子是空的，挺好。',
      'zh_CN': '小盒子是空的，挺好。',
      'en': 'Archive is empty. Good.',
    },
    'memory_inject_title': {
      'zh_TW': '記憶注入設定',
      'zh_CN': '记忆注入设定',
      'en': 'Memory Injection',
    },
    'memory_inject_hint': {
      'zh_TW': '控制每次對話注入的記憶 token 數量',
      'zh_CN': '控制每次对话注入的记忆 token 数量',
      'en': 'Control tokens injected per chat',
    },
    'memory_scheme': {'zh_TW': '記憶方案', 'zh_CN': '记忆方案', 'en': 'Memory Mode'},
    'memory_scheme_hint': {
      'zh_TW': '摘要開關與模型選擇於 API 設定中調整',
      'zh_CN': '摘要开关与模型选择于 API 设定中调整',
      'en': 'Summary switch and model live in API Settings',
    },
    'memory_mode_daily': {'zh_TW': '日常', 'zh_CN': '日常', 'en': 'Daily'},
    'memory_mode_plot': {'zh_TW': '劇情', 'zh_CN': '剧情', 'en': 'Plot'},
    'memory_mode_custom': {'zh_TW': '自定義', 'zh_CN': '自定义', 'en': 'Custom'},
    'memory_custom_prompt': {
      'zh_TW': '自定義記憶 Prompt',
      'zh_CN': '自定义记忆 Prompt',
      'en': 'Custom Memory Prompt',
    },
    'memory_fullscreen_edit': {
      'zh_TW': '全屏編輯',
      'zh_CN': '全屏编辑',
      'en': 'Fullscreen',
    },
    'memory_local_hint': {
      'zh_TW': '僅本地保存，不會注入對話',
      'zh_CN': '仅本地保存，不会注入对话',
      'en': 'Local only, not injected',
    },
    'memory_save': {'zh_TW': '儲存', 'zh_CN': '储存', 'en': 'Save'},
    'sticker_pick': {'zh_TW': '選擇表情包', 'zh_CN': '选择表情包', 'en': 'Pick Sticker'},
    'sticker_empty': {
      'zh_TW': '還沒有表情包',
      'zh_CN': '还没有表情包',
      'en': 'No stickers yet',
    },
    'sticker_title': {
      'zh_TW': '表情包庫',
      'zh_CN': '表情包库',
      'en': 'Sticker Library',
    },
    'sticker_add': {'zh_TW': '新增表情包', 'zh_CN': '新增表情包', 'en': 'Add Sticker'},
    'sticker_line': {'zh_TW': '台詞', 'zh_CN': '台词', 'en': 'Line'},
    'sticker_scene': {'zh_TW': '場景', 'zh_CN': '场景', 'en': 'Scene'},
    'sticker_select_char': {
      'zh_TW': '選擇人設卡',
      'zh_CN': '选择人设卡',
      'en': 'Select character',
    },
    'sticker_create_char': {
      'zh_TW': '請先建立人設卡',
      'zh_CN': '请先建立人设卡',
      'en': 'Create a character first',
    },
    'sticker_vision_btn': {
      'zh_TW': '讓 AI 看圖描述',
      'zh_CN': '让 AI 看图描述',
      'en': 'AI describe image',
    },
    'sticker_output_token': {
      'zh_TW': '輸出 token：',
      'zh_CN': '输出 token：',
      'en': 'Output tokens:',
    },
    'sticker_delete_confirm': {
      'zh_TW': '刪除這張表情包？',
      'zh_CN': '删除这张表情包？',
      'en': 'Delete this sticker?',
    },
    'sticker_empty_hint': {
      'zh_TW': '給對話加點風味。\n點右上角，從相冊挑。',
      'zh_CN': '给对话加点风味。\n点右上角，从相册挑。',
      'en': 'Add some flavor.\nTap + to pick from gallery.',
    },
    'char_title': {'zh_TW': '人設卡', 'zh_CN': '人设卡', 'en': 'Character'},
    'char_name': {'zh_TW': '角色名稱', 'zh_CN': '角色名称', 'en': 'Name'},
    'char_greeting': {'zh_TW': '開場白', 'zh_CN': '开场白', 'en': 'Greeting'},
    'char_avatar': {'zh_TW': '頭像', 'zh_CN': '头像', 'en': 'Avatar'},
    'char_save': {'zh_TW': '儲存角色', 'zh_CN': '储存角色', 'en': 'Save'},
    'char_delete': {'zh_TW': '刪除角色', 'zh_CN': '删除角色', 'en': 'Delete'},
    'char_list': {'zh_TW': '角色列表', 'zh_CN': '角色列表', 'en': 'Characters'},
    'char_new': {'zh_TW': '新增角色', 'zh_CN': '新增角色', 'en': 'New Character'},
    'char_upload_hint': {
      'zh_TW': '點擊上傳角色圖片',
      'zh_CN': '点击上传角色图片',
      'en': 'Tap to upload',
    },
    'char_more_attr': {'zh_TW': '更多屬性', 'zh_CN': '更多属性', 'en': 'More'},
    'char_settings': {
      'zh_TW': '角色設定',
      'zh_CN': '角色设定',
      'en': 'Character Settings',
    },
    'char_name_required': {
      'zh_TW': '請輸入角色名字',
      'zh_CN': '请输入角色名字',
      'en': 'Name required',
    },
    'char_in_use': {'zh_TW': '交流中', 'zh_CN': '交流中', 'en': 'Talking'},
    'char_empty_hint': {
      'zh_TW': '這裡會放你心裡的每一個人。\n點右上角，寫第一張。',
      'zh_CN': '这里会放你心里的每一个人。\n点右上角，写第一张。',
      'en': 'Your characters live here.\nTap + to create one.',
    },
    'char_create_hint': {
      'zh_TW': '先創建一個TA吧 →',
      'zh_CN': '先创建一个TA吧 →',
      'en': 'Create one →',
    },
    'char_share_code': {'zh_TW': '分享碼', 'zh_CN': '分享码', 'en': 'Share Code'},
    'char_import_code': {
      'zh_TW': '匯入分享碼',
      'zh_CN': '导入分享码',
      'en': 'Import Code',
    },
    'char_imported': {
      'zh_TW': '已匯入「{0}」',
      'zh_CN': '已导入「{0}」',
      'en': 'Imported "{0}"',
    },
    'char_delete_confirm': {
      'zh_TW': '確定要刪除「{0}」嗎？',
      'zh_CN': '确定要删除「{0}」吗？',
      'en': 'Delete "{0}"?',
    },
    'char_code_error': {
      'zh_TW': '分享碼格式錯誤',
      'zh_CN': '分享码格式错误',
      'en': 'Invalid share code',
    },
    'char_import_btn': {'zh_TW': '匯入', 'zh_CN': '导入', 'en': 'Import'},
    'copied_clipboard': {
      'zh_TW': '已複製到剪貼板',
      'zh_CN': '已复制到剪贴板',
      'en': 'Copied',
    },
    'theme_title': {'zh_TW': '主題工坊', 'zh_CN': '主题工坊', 'en': 'Theme Studio'},
    'theme_preset': {'zh_TW': '預設主題', 'zh_CN': '预设主题', 'en': 'Presets'},
    'theme_custom': {'zh_TW': '自定義微調', 'zh_CN': '自定义微调', 'en': 'Custom'},
    'theme_bubble_opacity': {
      'zh_TW': '氣泡透明度',
      'zh_CN': '气泡透明度',
      'en': 'Bubble Opacity',
    },
    'theme_bubble_radius': {
      'zh_TW': '氣泡圓角',
      'zh_CN': '气泡圆角',
      'en': 'Bubble Radius',
    },
    'theme_star': {'zh_TW': '星空背景', 'zh_CN': '星空背景', 'en': 'Starfield'},
    'theme_font': {'zh_TW': '字體', 'zh_CN': '字体', 'en': 'Font'},
    'theme_font_size': {'zh_TW': '字體大小', 'zh_CN': '字体大小', 'en': 'Font Size'},
    'theme_pick_color': {
      'zh_TW': '選一個底色',
      'zh_CN': '选一个底色',
      'en': 'Pick a color',
    },
    'theme_bubble': {'zh_TW': '氣泡', 'zh_CN': '气泡', 'en': 'Bubble'},
    'theme_starlight': {'zh_TW': '背景特效', 'zh_CN': '背景特效', 'en': 'Effects'},
    'theme_star_particle': {
      'zh_TW': '粒子特效',
      'zh_CN': '粒子特效',
      'en': 'Particle effects',
    },
    'theme_advanced': {'zh_TW': '進階設定', 'zh_CN': '进阶设定', 'en': 'Advanced'},
    'theme_apply': {'zh_TW': '套用', 'zh_CN': '套用', 'en': 'Apply'},
    'theme_hex': {'zh_TW': '色號（HEX）', 'zh_CN': '色号（HEX）', 'en': 'HEX Code'},
    'theme_value': {'zh_TW': '數值', 'zh_CN': '数值', 'en': 'Value'},
    'theme_preview_hi': {'zh_TW': '你好呀', 'zh_CN': '你好呀', 'en': 'Hello~'},
    'theme_preview_reply': {'zh_TW': '嗯，在的', 'zh_CN': '嗯，在的', 'en': 'Mm, here'},
    'usage_header': {'zh_TW': '用量', 'zh_CN': '用量', 'en': 'Usage'},
    'usage_title': {'zh_TW': '用量統計', 'zh_CN': '用量统计', 'en': 'Usage'},
    'usage_today': {'zh_TW': '今日', 'zh_CN': '今日', 'en': 'Today'},
    'usage_total': {'zh_TW': '累計', 'zh_CN': '累计', 'en': 'Total'},
    'usage_no_data': {
      'zh_TW': '聊了才有數據～',
      'zh_CN': '聊了才有数据～',
      'en': 'Chat to see data~',
    },
    'usage_model_dist': {
      'zh_TW': '模型分佈',
      'zh_CN': '模型分布',
      'en': 'Model Distribution',
    },
    'note_title': {'zh_TW': '便利貼', 'zh_CN': '便利贴', 'en': 'Notes'},
    'note_empty': {'zh_TW': '還沒有便利貼', 'zh_CN': '还没有便利贴', 'en': 'No notes yet'},
    'greeting_morning': {'zh_TW': '早安', 'zh_CN': '早安', 'en': 'Good morning'},
    'greeting_afternoon': {
      'zh_TW': '午安',
      'zh_CN': '午安',
      'en': 'Good afternoon',
    },
    'greeting_evening': {'zh_TW': '晚安', 'zh_CN': '晚安', 'en': 'Good evening'},
    'greeting_night': {'zh_TW': '夜深了', 'zh_CN': '夜深了', 'en': 'Late night'},
    'first_time_title': {
      'zh_TW': '怎麼稱呼你？',
      'zh_CN': '怎么称呼你？',
      'en': 'What should I call you?',
    },
    'first_time_hint': {
      'zh_TW': '輸入暱稱……',
      'zh_CN': '输入昵称……',
      'en': 'Enter your name...',
    },
    'first_time_skip': {'zh_TW': '先跳過', 'zh_CN': '先跳过', 'en': 'Skip'},
    'sub_settings_title': {'zh_TW': '設定', 'zh_CN': '设定', 'en': 'Settings'},
    'me_settings': {'zh_TW': '設置', 'zh_CN': '设置', 'en': 'Settings'},
    'me_tap_edit': {'zh_TW': '點擊編輯', 'zh_CN': '点击编辑', 'en': 'Tap to edit'},
    'me_backup_title': {'zh_TW': '備份', 'zh_CN': '备份', 'en': 'Backup'},
    'me_backup_auto_title': {
      'zh_TW': '自動本地備份',
      'zh_CN': '自动本地备份',
      'en': 'Auto local backup',
    },
    'me_backup_auto_sub': {
      'zh_TW': '啟動、每小時與進入背景時覆蓋保存',
      'zh_CN': '启动、每小时与进入后台时覆盖保存',
      'en': 'Overwrites on launch, hourly, and when backgrounded',
    },
    'me_backup_last': {
      'zh_TW': '最近備份：{0}',
      'zh_CN': '最近备份：{0}',
      'en': 'Last backup: {0}',
    },
    'me_backup_never': {'zh_TW': '尚未備份', 'zh_CN': '尚未备份', 'en': 'Never'},
    'me_import_json': {'zh_TW': '導入數據', 'zh_CN': '导入数据', 'en': 'Import JSON'},
    'me_import_json_sub': {
      'zh_TW': '從備份還原',
      'zh_CN': '从备份还原',
      'en': 'Restore from backup',
    },
    'backup_importing': {'zh_TW': '導入中…', 'zh_CN': '导入中…', 'en': 'Importing…'},
    'backup_import_done': {
      'zh_TW': '導入完成：{0}',
      'zh_CN': '导入完成：{0}',
      'en': 'Imported: {0}',
    },
    'backup_no_files': {
      'zh_TW': '沒有找到備份文件',
      'zh_CN': '没有找到备份文件',
      'en': 'No backup files found',
    },
    'backup_select_file': {
      'zh_TW': '選擇備份文件',
      'zh_CN': '选择备份文件',
      'en': 'Select backup file',
    },
    'me_export_json': {'zh_TW': '導出數據', 'zh_CN': '导出数据', 'en': 'Export JSON'},
    'me_export_json_sub': {
      'zh_TW': 'JSON 格式',
      'zh_CN': 'JSON 格式',
      'en': 'JSON format',
    },
    'me_local_backup': {'zh_TW': '本地備份', 'zh_CN': '本地备份', 'en': 'Local Backup'},
    'me_local_backup_sub': {
      'zh_TW': '覆蓋保存',
      'zh_CN': '覆盖保存',
      'en': 'Overwrite save',
    },
    'backup_exporting': {'zh_TW': '導出中…', 'zh_CN': '导出中…', 'en': 'Exporting…'},
    'backup_saving': {'zh_TW': '備份中…', 'zh_CN': '备份中…', 'en': 'Saving…'},
    'backup_export_done': {
      'zh_TW': '已導出至 {0}',
      'zh_CN': '已导出至 {0}',
      'en': 'Exported to {0}',
    },
    'backup_save_done': {'zh_TW': '已備份', 'zh_CN': '已备份', 'en': 'Backed up'},
    'backup_error': {
      'zh_TW': '備份失敗：{0}',
      'zh_CN': '备份失败：{0}',
      'en': 'Backup failed: {0}',
    },
    'settings_font': {'zh_TW': '字體', 'zh_CN': '字体', 'en': 'Font'},
    'history_title': {'zh_TW': '歷史對話', 'zh_CN': '历史对话', 'en': 'History'},
    'history_empty': {
      'zh_TW': '還沒有故事開始。\n點水晶球，開一個。',
      'zh_CN': '还没有故事开始。\n点水晶球，开一个。',
      'en': 'No chats yet.\nTap the orb to start.',
    },
    'history_edit_title': {
      'zh_TW': '編輯標題',
      'zh_CN': '编辑标题',
      'en': 'Edit Title',
    },
    'history_recall': {'zh_TW': '回憶', 'zh_CN': '回忆', 'en': 'Recall'},
    'font_preview': {
      'zh_TW': '永遠不要停止追尋 abcdef',
      'zh_CN': '永远不要停止追寻 abcdef',
      'en': 'Never stop exploring abcdef',
    },
    'profile_title': {'zh_TW': '用戶檔案', 'zh_CN': '用户档案', 'en': 'Profile'},
    'profile_name': {'zh_TW': '暱稱', 'zh_CN': '昵称', 'en': 'Nickname'},
    'profile_pronoun': {
      'zh_TW': '稱謂 / 代詞',
      'zh_CN': '称谓 / 代词',
      'en': 'Pronouns',
    },
    'profile_bio': {'zh_TW': '自我介紹', 'zh_CN': '自我介绍', 'en': 'About me'},
    'tts_voice': {'zh_TW': '聲音', 'zh_CN': '声音', 'en': 'Voice'},
    'tts_model': {'zh_TW': '模型', 'zh_CN': '模型', 'en': 'Model'},
    'n_items': {'zh_TW': '{0} 條', 'zh_CN': '{0} 条', 'en': '{0}'},
    'n_memories': {
      'zh_TW': '{0} 條記憶',
      'zh_CN': '{0} 条记忆',
      'en': '{0} memories',
    },
    'n_archived': {
      'zh_TW': '{0} 條歸檔',
      'zh_CN': '{0} 条归档',
      'en': '{0} archived',
    },
    'n_period_total': {'zh_TW': '{0}累計', 'zh_CN': '{0}累计', 'en': '{0} Total'},
    'n_reqs_tokens': {
      'zh_TW': '{0} 次 · {1} tokens',
      'zh_CN': '{0} 次 · {1} tokens',
      'en': '{0} calls · {1} tokens',
    },
    'sticker_added_n': {
      'zh_TW': '已添加 {0} 張',
      'zh_CN': '已添加 {0} 张',
      'en': 'Added {0}',
    },
    'confirm': {'zh_TW': '確認', 'zh_CN': '确认', 'en': 'Confirm'},
    'confirm_ok': {'zh_TW': '確定', 'zh_CN': '确定', 'en': 'OK'},
    'confirm_delete': {'zh_TW': '確認刪除', 'zh_CN': '确认删除', 'en': 'Delete'},
    'cancel': {'zh_TW': '取消', 'zh_CN': '取消', 'en': 'Cancel'},
    'save': {'zh_TW': '儲存', 'zh_CN': '储存', 'en': 'Save'},
    'settings_save': {'zh_TW': '保存', 'zh_CN': '保存', 'en': 'Save'},
    'delete': {'zh_TW': '刪除', 'zh_CN': '删除', 'en': 'Delete'},
    'saved': {'zh_TW': '已儲存', 'zh_CN': '已储存', 'en': 'Saved'},
    'error': {'zh_TW': '出錯了', 'zh_CN': '出错了', 'en': 'Error'},

    // ── input bar ──
    'input_hint': {'zh_TW': '我在……', 'zh_CN': '我在……', 'en': 'I\'m here...'},

    // ── settings: API / model ──
    'settings_fetch_models': {
      'zh_TW': '獲取可用模型',
      'zh_CN': '获取可用模型',
      'en': 'Fetch Models',
    },
    'settings_model_label': {'zh_TW': '模型', 'zh_CN': '模型', 'en': 'Model'},
    'settings_model_hint_empty': {
      'zh_TW': '輸入模型 ID（或先獲取列表）',
      'zh_CN': '输入模型 ID（或先获取列表）',
      'en': 'Enter model ID (or fetch list)',
    },
    'settings_model_hint_search': {
      'zh_TW': '搜索模型……',
      'zh_CN': '搜索模型……',
      'en': 'Search models...',
    },
    'settings_model_error': {
      'zh_TW': '無法獲取模型列表',
      'zh_CN': '无法获取模型列表',
      'en': 'Failed to fetch models',
    },
    'settings_model_error_no_key': {
      'zh_TW': '請先輸入 OpenRouter API Key',
      'zh_CN': '请先输入 OpenRouter API Key',
      'en': 'Enter an OpenRouter API key first',
    },
    'settings_model_error_fetch': {
      'zh_TW': '獲取模型列表失敗',
      'zh_CN': '获取模型列表失败',
      'en': 'Failed to fetch models',
    },
    'settings_prompt_hint': {
      'zh_TW': '在此輸入角色設定……',
      'zh_CN': '在此输入角色设定……',
      'en': 'Enter character prompt...',
    },
    'settings_api_source': {
      'zh_TW': 'API 來源',
      'zh_CN': 'API 来源',
      'en': 'API Provider',
    },
    'settings_gemini_direct': {
      'zh_TW': 'Gemini 直連',
      'zh_CN': 'Gemini 直连',
      'en': 'Gemini Direct',
    },
    'settings_deepseek_direct': {
      'zh_TW': 'DeepSeek 直連',
      'zh_CN': 'DeepSeek 直连',
      'en': 'DeepSeek Direct',
    },
    'settings_context_title': {
      'zh_TW': '上下文發送限制',
      'zh_CN': '上下文发送限制',
      'en': 'Context Send Limit',
    },
    'settings_context_detail': {
      'zh_TW': '0 = 不限制。數字越小發送的歷史越少，省 token 但記憶短',
      'zh_CN': '0 = 不限制。数字越小发送的历史越少，省 token 但记忆短',
      'en':
          '0 = unlimited. Lower values send less history, saves tokens but shorter memory',
    },
    'settings_vibration_title': {
      'zh_TW': '回覆震動',
      'zh_CN': '回复震动',
      'en': 'Reply Haptic',
    },
    'settings_sticker_vision_title': {
      'zh_TW': '表情包 Vision 模型',
      'zh_CN': '表情包 Vision 模型',
      'en': 'Sticker Vision Model',
    },
    'settings_tts_title': {
      'zh_TW': '語音 TTS',
      'zh_CN': '语音 TTS',
      'en': 'Voice TTS',
    },
    'settings_tts_openai_hint': {
      'zh_TW': 'OpenAI API Key（TTS 用）',
      'zh_CN': 'OpenAI API Key（TTS 用）',
      'en': 'OpenAI API Key (for TTS)',
    },
    'settings_same_as_main': {
      'zh_TW': '跟主模型一樣',
      'zh_CN': '跟主模型一样',
      'en': 'Same as main model',
    },

    // ── call screen pronouns ──
    'call_pronoun_me': {'zh_TW': '我', 'zh_CN': '我', 'en': 'Me'},
    'call_pronoun_her': {'zh_TW': '她', 'zh_CN': '她', 'en': 'Her'},
    'call_pronoun_him': {'zh_TW': '他', 'zh_CN': '他', 'en': 'Him'},

    // ── usage ──
    'usage_period_today': {'zh_TW': '今天', 'zh_CN': '今天', 'en': 'Today'},
    'usage_period_week': {'zh_TW': '本週', 'zh_CN': '本周', 'en': 'This Week'},
    'usage_period_month': {'zh_TW': '本月', 'zh_CN': '本月', 'en': 'This Month'},
    'usage_requests': {'zh_TW': '次請求', 'zh_CN': '次请求', 'en': 'requests'},
    'usage_cache_hit': {'zh_TW': '緩存命中', 'zh_CN': '缓存命中', 'en': 'cache hits'},

    // ── character card ──
    'char_edit_title': {
      'zh_TW': '編輯人設卡',
      'zh_CN': '编辑人设卡',
      'en': 'Edit Character',
    },
    'char_new_title': {
      'zh_TW': '新建人設卡',
      'zh_CN': '新建人设卡',
      'en': 'New Character',
    },
    'char_name_label': {'zh_TW': '姓名', 'zh_CN': '姓名', 'en': 'Name'},
    'char_gender_label': {'zh_TW': '性別', 'zh_CN': '性别', 'en': 'Gender'},
    'char_gender_hint': {'zh_TW': '可空', 'zh_CN': '可空', 'en': 'Optional'},
    'char_relation_label': {'zh_TW': '關係', 'zh_CN': '关系', 'en': 'Relation'},
    'char_relation_hint': {'zh_TW': '可空', 'zh_CN': '可空', 'en': 'Optional'},
    'char_tab_voice': {'zh_TW': '語音', 'zh_CN': '语音', 'en': 'Voice'},
    'char_tab_sticker': {
      'zh_TW': '專屬表情庫',
      'zh_CN': '专属表情库',
      'en': 'Exclusive Stickers',
    },
    'char_tab_memory': {'zh_TW': '記憶', 'zh_CN': '记忆', 'en': 'Memory'},
    'char_tab_saved': {'zh_TW': '收藏', 'zh_CN': '收藏', 'en': 'Saved'},
    'char_use': {'zh_TW': '交流', 'zh_CN': '交流', 'en': 'Talk'},
    'saved_empty': {
      'zh_TW': '還沒有收藏',
      'zh_CN': '还没有收藏',
      'en': 'No saved messages',
    },
    'char_desc_hint': {
      'zh_TW': '角色設定、性格、說話方式……想寫多長就多長',
      'zh_CN': '角色设定、性格、说话方式……想写多长就多长',
      'en': 'Personality, speaking style... write as much as you want',
    },
    'char_desc_hint_short': {
      'zh_TW': '角色設定、性格、說話方式……',
      'zh_CN': '角色设定、性格、说话方式……',
      'en': 'Personality, speaking style...',
    },
    'char_race': {'zh_TW': '種族', 'zh_CN': '种族', 'en': 'Race'},
    'char_race_hint': {
      'zh_TW': '人類、精靈……',
      'zh_CN': '人类、精灵……',
      'en': 'Human, Elf...',
    },
    'char_skill_label': {'zh_TW': '技能', 'zh_CN': '技能', 'en': 'Skill'},
    'char_skill_hint': {
      'zh_TW': '劍術、魔法……',
      'zh_CN': '剑术、魔法……',
      'en': 'Swordsmanship, Magic...',
    },
    'char_age': {'zh_TW': '年齡', 'zh_CN': '年龄', 'en': 'Age'},
    'char_height_label': {'zh_TW': '身高', 'zh_CN': '身高', 'en': 'Height'},
    'char_ready': {'zh_TW': '我準備好了', 'zh_CN': '我准备好了', 'en': 'I\'m ready'},
    'char_ready_named': {
      'zh_TW': '{0}，我準備好了',
      'zh_CN': '{0}，我准备好了',
      'en': '{0}, I\'m ready',
    },
    'char_gender_f': {'zh_TW': '女', 'zh_CN': '女', 'en': 'Female'},
    'char_gender_m': {'zh_TW': '男', 'zh_CN': '男', 'en': 'Male'},
    'char_gender_nb': {'zh_TW': '無性別', 'zh_CN': '无性别', 'en': 'Non-binary'},
    'char_gender_other': {'zh_TW': '其他', 'zh_CN': '其他', 'en': 'Other'},
    'char_relation_lover': {'zh_TW': '戀人', 'zh_CN': '恋人', 'en': 'Lover'},
    'char_relation_friend': {'zh_TW': '朋友', 'zh_CN': '朋友', 'en': 'Friend'},
    'char_relation_family': {'zh_TW': '家人', 'zh_CN': '家人', 'en': 'Family'},
    'char_relation_partner': {'zh_TW': '夥伴', 'zh_CN': '伙伴', 'en': 'Partner'},
    'char_relation_other': {'zh_TW': '其他', 'zh_CN': '其他', 'en': 'Other'},
    'char_colon': {'zh_TW': '：', 'zh_CN': '：', 'en': ': '},

    // ── theme workshop ──
    'theme_opacity_label': {'zh_TW': '透明度', 'zh_CN': '透明度', 'en': 'Opacity'},
    'theme_radius_label': {'zh_TW': '圓角', 'zh_CN': '圆角', 'en': 'Radius'},
    'theme_density_label': {'zh_TW': '密度', 'zh_CN': '密度', 'en': 'Density'},
    'theme_bg1': {'zh_TW': '背景色 1', 'zh_CN': '背景色 1', 'en': 'Background 1'},
    'theme_bg2': {'zh_TW': '背景色 2', 'zh_CN': '背景色 2', 'en': 'Background 2'},
    'theme_bg3': {'zh_TW': '背景色 3', 'zh_CN': '背景色 3', 'en': 'Background 3'},
    'theme_bg4': {'zh_TW': '背景色 4', 'zh_CN': '背景色 4', 'en': 'Background 4'},
    'theme_ai_bubble': {'zh_TW': 'AI 氣泡', 'zh_CN': 'AI 气泡', 'en': 'AI Bubble'},
    'theme_user_bubble': {
      'zh_TW': '用戶氣泡',
      'zh_CN': '用户气泡',
      'en': 'User Bubble',
    },
    'theme_text_primary': {
      'zh_TW': '主文字',
      'zh_CN': '主文字',
      'en': 'Primary Text',
    },
    'theme_text_secondary': {
      'zh_TW': '次要文字',
      'zh_CN': '次要文字',
      'en': 'Secondary Text',
    },
    'theme_accent_color': {'zh_TW': '強調色', 'zh_CN': '强调色', 'en': 'Accent'},
    'theme_star_color': {'zh_TW': '星光色', 'zh_CN': '星光色', 'en': 'Star Color'},
    'theme_star_density': {
      'zh_TW': '星光密度',
      'zh_CN': '星光密度',
      'en': 'Star Density',
    },

    // ── memory screen ──
    'memory_total_budget': {
      'zh_TW': '總預算 ≈ {0} tokens',
      'zh_CN': '总预算 ≈ {0} tokens',
      'en': 'Total budget ≈ {0} tokens',
    },
    'memory_archive_no_inject': {
      'zh_TW': '積灰小盒子不會注入，僅本地查看',
      'zh_CN': '积灰小盒子不会注入，仅本地查看',
      'en': 'Archive is local only, not injected',
    },
    'memory_mode_daily_desc': {
      'zh_TW': '適合陪伴聊天、關係養成。記錄情緒轉折、偏好習慣、約定承諾。',
      'zh_CN': '适合陪伴聊天、关系养成。记录情绪转折、偏好习惯、约定承诺。',
      'en':
          'For companionship chats. Tracks emotional shifts, preferences, promises.',
    },
    'memory_mode_plot_desc': {
      'zh_TW': '適合世界觀 RP、長篇敘事。追蹤伏筆、角色弧光、不可逆事件。',
      'zh_CN': '适合世界观 RP、长篇叙事。追踪伏笔、角色弧光、不可逆事件。',
      'en':
          'For worldbuilding RP & long narratives. Tracks foreshadowing, character arcs, irreversible events.',
    },
    'memory_mode_custom_desc': {
      'zh_TW': '完全由你定義記憶規則。適合嫌 token 太長或有特殊需求的用戶。',
      'zh_CN': '完全由你定义记忆规则。适合嫌 token 太长或有特殊需求的用户。',
      'en':
          'Fully custom memory rules. For users who want precise token control.',
    },
    'memory_mode_daily_token': {
      'zh_TW': '≈ 800 tokens/次',
      'zh_CN': '≈ 800 tokens/次',
      'en': '≈ 800 tokens/call',
    },
    'memory_mode_plot_token': {
      'zh_TW': '≈ 1800 tokens/次',
      'zh_CN': '≈ 1800 tokens/次',
      'en': '≈ 1800 tokens/call',
    },
    'memory_mode_custom_token': {
      'zh_TW': '取決於你的 prompt',
      'zh_CN': '取决于你的 prompt',
      'en': 'Depends on your prompt',
    },
    'memory_long_empty': {
      'zh_TW': '聊久了自然會記住。',
      'zh_CN': '聊久了自然会记住。',
      'en': 'Chat more and memories will form.',
    },
    'memory_unfinished_empty': {
      'zh_TW': '沒有未完成的事。',
      'zh_CN': '没有未完成的事。',
      'en': 'Nothing pending.',
    },
    'memory_all_empty': {
      'zh_TW': '還沒有累積。',
      'zh_CN': '还没有累积。',
      'en': 'Nothing yet.',
    },
    'memory_observe_empty': {
      'zh_TW': '安靜地觀察中。',
      'zh_CN': '安静地观察中。',
      'en': 'Quietly observing.',
    },
    'memory_observe_title': {'zh_TW': '觀察區', 'zh_CN': '观察区', 'en': 'Observing'},
    'memory_confirm_delete_section': {
      'zh_TW': '確定要刪除「{0}」中的所有記憶嗎？\n此操作不可恢復。',
      'zh_CN': '确定要删除「{0}」中的所有记忆吗？\n此操作不可恢复。',
      'en': 'Delete all memories in "{0}"?\nThis cannot be undone.',
    },
    'memory_confirm_delete_one': {
      'zh_TW': '確定要刪除這條長期記憶嗎？\n刪除後會移到積灰小盒子。',
      'zh_CN': '确定要删除这条长期记忆吗？\n删除后会移到积灰小盒子。',
      'en': 'Delete this memory?\nIt will be moved to archive.',
    },
    'memory_confirm_clear_archive': {
      'zh_TW': '確定要清空所有歸檔記憶嗎？\n此操作不可恢復。',
      'zh_CN': '确定要清空所有归档记忆吗？\n此操作不可恢复。',
      'en': 'Clear all archived memories?\nThis cannot be undone.',
    },
    'memory_empty_default': {'zh_TW': '空的', 'zh_CN': '空的', 'en': 'Empty'},
    'memory_confirm_delete_perm': {
      'zh_TW': '永久刪除？不可恢復。',
      'zh_CN': '永久删除？不可恢复。',
      'en': 'Delete permanently? Cannot be undone.',
    },

    // ── sticker tags ──
    'tag_開心': {'zh_TW': '開心', 'zh_CN': '开心', 'en': 'Happy'},
    'tag_害羞': {'zh_TW': '害羞', 'zh_CN': '害羞', 'en': 'Shy'},
    'tag_生氣': {'zh_TW': '生氣', 'zh_CN': '生气', 'en': 'Angry'},
    'tag_委屈': {'zh_TW': '委屈', 'zh_CN': '委屈', 'en': 'Hurt'},
    'tag_無語': {'zh_TW': '無語', 'zh_CN': '无语', 'en': 'Speechless'},
    'tag_撒嬌': {'zh_TW': '撒嬌', 'zh_CN': '撒娇', 'en': 'Clingy'},
    'tag_得意': {'zh_TW': '得意', 'zh_CN': '得意', 'en': 'Smug'},
    'tag_震驚': {'zh_TW': '震驚', 'zh_CN': '震惊', 'en': 'Shocked'},
    'tag_心動': {'zh_TW': '心動', 'zh_CN': '心动', 'en': 'Smitten'},
    'tag_嫌棄': {'zh_TW': '嫌棄', 'zh_CN': '嫌弃', 'en': 'Disdain'},
    'tag_困': {'zh_TW': '困', 'zh_CN': '困', 'en': 'Sleepy'},
    'tag_哭': {'zh_TW': '哭', 'zh_CN': '哭', 'en': 'Crying'},
    'tag_笑哭': {'zh_TW': '笑哭', 'zh_CN': '笑哭', 'en': 'LOL'},
    'tag_期待': {'zh_TW': '期待', 'zh_CN': '期待', 'en': 'Excited'},
    'tag_拒絕': {'zh_TW': '拒絕', 'zh_CN': '拒绝', 'en': 'Nope'},
    'tag_心疼': {'zh_TW': '心疼', 'zh_CN': '心疼', 'en': 'Aching'},
    'tag_發呆': {'zh_TW': '發呆', 'zh_CN': '发呆', 'en': 'Zoning'},
    'tag_嘴硬': {'zh_TW': '嘴硬', 'zh_CN': '嘴硬', 'en': 'Tsun'},
    'tag_偷看': {'zh_TW': '偷看', 'zh_CN': '偷看', 'en': 'Peeking'},
    'tag_裝死': {'zh_TW': '裝死', 'zh_CN': '装死', 'en': 'Playing dead'},

    // ── sticker ──
    'sticker_tab_label': {'zh_TW': '標籤', 'zh_CN': '标签', 'en': 'Tags'},
    'sticker_tab_manual': {'zh_TW': '手動', 'zh_CN': '手动', 'en': 'Manual'},
    'sticker_line_hint': {
      'zh_TW': '角色看到這張圖會說的話',
      'zh_CN': '角色看到这张图会说的话',
      'en': 'What the character would say',
    },
    'sticker_scene_hint': {
      'zh_TW': '什麼場景下會用',
      'zh_CN': '什么场景下会用',
      'en': 'When to use this',
    },
    'sticker_mood': {'zh_TW': '情緒詞', 'zh_CN': '情绪词', 'en': 'Mood'},
    'sticker_mood_hint': {
      'zh_TW': '開心, 害羞, 嘴硬',
      'zh_CN': '开心, 害羞, 嘴硬',
      'en': 'happy, shy, stubborn',
    },
    'sticker_line_manual_hint': {
      'zh_TW': '這張圖代表的一句話',
      'zh_CN': '这张图代表的一句话',
      'en': 'A line this image represents',
    },
    'sticker_scene_manual_hint': {
      'zh_TW': '什麼場景下會用（可留空）',
      'zh_CN': '什么场景下会用（可留空）',
      'en': 'When to use (optional)',
    },
    'sticker_mood_manual_hint': {
      'zh_TW': '開心, 害羞, 嘴硬（可留空）',
      'zh_CN': '开心, 害羞, 嘴硬（可留空）',
      'en': 'happy, shy, stubborn (optional)',
    },
    'sticker_char_fallback': {'zh_TW': '角色', 'zh_CN': '角色', 'en': 'Character'},

    // ── theme presets ──
    'theme_preset_dawn': {'zh_TW': '晨光', 'zh_CN': '晨光', 'en': 'Dawn'},
    'theme_preset_midnight': {
      'zh_TW': '深夜書房',
      'zh_CN': '深夜书房',
      'en': 'Midnight',
    },
    'theme_preset_bamboo': {'zh_TW': '墨竹', 'zh_CN': '墨竹', 'en': 'Bamboo'},
    'theme_preset_ivory': {'zh_TW': '象牙白', 'zh_CN': '象牙白', 'en': 'Ivory'},
    'theme_preset_amber': {'zh_TW': '琥珀', 'zh_CN': '琥珀', 'en': 'Amber'},
    'theme_preset_mist': {'zh_TW': '霧紫', 'zh_CN': '雾紫', 'en': 'Mist'},
    'theme_preset_seafoam': {'zh_TW': '海鹽', 'zh_CN': '海盐', 'en': 'Seafoam'},
    'theme_preset_blush': {'zh_TW': '玫瑰露', 'zh_CN': '玫瑰露', 'en': 'Rose Dew'},
    'theme_preset_bloom': {'zh_TW': '花信', 'zh_CN': '花信', 'en': 'Bloom'},
    'theme_preset_iced': {'zh_TW': '冬夜', 'zh_CN': '冬夜', 'en': 'Winter Night'},
    'theme_preset_nightlamp': {
      'zh_TW': '夜燈',
      'zh_CN': '夜灯',
      'en': 'Night Lamp',
    },
    'theme_preset_tipsy': {'zh_TW': '微醺', 'zh_CN': '微醺', 'en': 'Tipsy'},
    'theme_preset_snow': {'zh_TW': '初雪', 'zh_CN': '初雪', 'en': 'First Snow'},
    'theme_preset_latte': {'zh_TW': '奶咖', 'zh_CN': '奶咖', 'en': 'Latte'},
    'theme_preset_soda': {
      'zh_TW': '海鹽蘇打',
      'zh_CN': '海盐苏打',
      'en': 'Sea Salt Soda',
    },
    'theme_preset_neon': {'zh_TW': '霓虹雨', 'zh_CN': '霓虹雨', 'en': 'Neon Rain'},

    // ── home ──
    'note_hint': {
      'zh_TW': '留一句話，下次打開就看得到。',
      'zh_CN': '留一句话，下次打开就看得到。',
      'en': 'Leave a note for next time.',
    },
    'note_write_hint': {
      'zh_TW': '寫點什麼……',
      'zh_CN': '写点什么……',
      'en': 'Write something...',
    },
    'history_label': {'zh_TW': '歷史', 'zh_CN': '历史', 'en': 'History'},
  };
}
