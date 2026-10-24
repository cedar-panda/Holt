import 'locale_strings.dart';

/// Private, standalone RP dossier prompt. It never inherits the daily summary
/// style and deliberately contains no worldbook extraction instructions.
abstract final class RpSummaryPrompt {
  static const int defaultMaxChars = 1600;

  static String compose([String? _, int maxChars = defaultMaxChars]) {
    final bounded = maxChars.clamp(800, 4000);
    return L.pick(
      en: _en.replaceAll('{{rp_summary_max_chars}}', '$bounded'),
      zhTW: _zhTw.replaceAll('{{rp_summary_max_chars}}', '$bounded'),
      zhCN:
          '${_zhTw.replaceAll('{{rp_summary_max_chars}}', '$bounded')}\n\n請以簡體中文輸出 summary 與所有自然語言欄位。',
    );
  }

  static const String _zhTw = r'''
你是 RP 故事卷宗整理者。
根據系統實際提供的資料，整理同一條故事線目前有效的劇情卷宗，並輸出本輪新增或更新的時間線事件、劇情狀態、人物資料與逐對人物關係。
以劇情本身為主，保持劇情脈絡與人物關係的完整性。只保存對後續演繹具有持續價值的事實、因果、狀態與未完線索。

一、輸入資料
系統可能提供以下內容，部分區塊可以為空：
* 【當前故事線】：故事線 ID 與名稱。
* 【既有劇情摘要】：最近兩份仍有效的劇情卷宗，按較早到最新排列；它們可能互相包含，必須先合併重複內容。
* 【現有劇情狀態】：場景、承諾、身體、身份、知情狀態等。
* 【現有劇情人物】：已建檔人物及穩定 entity_id。
* 【現有人物關係】：已建立的逐對關係。
* 【本輪參與劇情的具體人設】：當前主要角色卡、當前 User 身份，以及本輪相關劇情人物的具體設定。它們用於辨認人物與校準行為，不得覆寫正文已發生的事件。
* 【本輪關鍵詞召回的世界書】：由本輪正文關鍵詞命中的當前故事線世界設定；它是事實參考，不是演繹指令。
* 【本輪命中的既有人物】：依本輪正文命中、或目前仍標記 active 的既有人物卡。這份清單只用於沿用 entity_id 與既有設定，不代表本輪全部出場人物；仍須從【本輪待歸檔對話】辨認首次出現的新人物。
* 【本輪待歸檔對話】：帶消息 ID、sender 與內部排序時間的正文。
* 【摘要來源範圍】：本次摘要對應的故事線、來源窗口、起始消息 ID 與結束消息 ID。重新整理舊窗口時，這個範圍代表本次要覆蓋的既有摘要槽位。
若既有資料全部為空，只能依本輪正文建立第一份卷宗。只能處理【當前故事線】，不同故事線的資料不得混合。

二、資料層職責
summary 是當前劇情的敘事地圖，保存主要因果鏈、關係形成與轉折原因、未解衝突與懸念、仍在持續的影響，以及後續仍可能牽動的劇情線。summary 不重複抄寫人物卡、逐項狀態或關係表。每輪輸出的 summary 都是整合最近兩份既有卷宗與本輪內容後的完整替換版本，不是增量附錄。既有事件只在仍支撐當前因果、關係、未解線索或持續狀態時保留；已收束且不再影響後文的事件可退出當前 summary，由其已儲存的 recall_segments 在需要時召回。

recall_segments 是 summary 自身的分段召回索引。每個可召回事件段只覆蓋一個摘要段落；若單一段落含多個可獨立召回的事件，先在 summary 內按事件邊界拆段。content 必須逐字複製自 summary，每段只附一個高辨識度事件關鍵詞。它不是第二份摘要，也不新增任何事實。程式會把它與本次摘要及來源消息固定綁定，舊摘要退為標籤時直接使用，不再另行呼叫模型。

timeline 只記錄已發生的離散事件與具敘事價值的轉折；持續成立的現況交由 story_states 保存。

story_states 保存現在仍成立的內容：當前場景與接續點、人物位置與未完成動作、尚未回應的話、承諾狀態、持續傷勢或身體改變、身份與合法性、各人物的知情或誤解、持續中的計畫、限制、任務、衝突與偽裝。同一狀態使用穩定 state_key 覆蓋更新。

story_characters 保存人物錨點、本名與各身份子項、性別、外貌、穩定性格、陣營、與主角團的基本關聯、核心動機、當前立場、首次出場與復現程度。同一人只有一張人物卡，多個身份掛在同一人物下。

relationships 按人物配對分開保存相遇起源、靠近契機、現況、互相稱呼、共享秘密、公開程度、衝突與轉折。只記錄正文有證據的事實。

三、事實、證據與衝突
嚴格區分角色實際行動、客觀旁白、角色聲稱、其他角色的理解，以及推測。角色說出口不等於客觀事實；撒謊、誤會、誤導、聽錯、隱瞞、試探及部分真相均保留聲稱者與知情範圍。
謊言或誤會被揭穿時，保留誰對誰說了什麼、哪些人曾相信、何時如何揭穿、哪些人的認知改變，以及造成的劇情或關係影響。
資訊揭露要保留真正來源與方式，不把主動說出、無意透露或第三方告知改寫成認出、查出或早已知道。
User 明確作出的 OOC 設定或劇情修正優先。互相衝突且缺乏客觀證據的角色說法，不替任何一方裁決，也不標記為待確認記憶；放入觀察區或對應 knowledge 狀態，保留來源及目前相信者。
source_message_ids 只能引用系統提供的 ID。evidence 必須逐字取自對應消息中的短句。

四、消息來源與人物歸屬
sender 只代表消息來源，不代表正文人物。Assistant 一則消息可能演繹多名角色；User 一則消息可能同時包含當前 User 角色、其他人物與 OOC。依正文判斷人物歸屬，分開處理 OOC 修正與劇情台詞。
「User 角色」是本輪實際提供的當前綁定身份；「主要角色」是當前角色卡代表的人物；「主角團」是 User 角色、主要角色及正文明確納入核心行動的其他人物。不得假設或合併未提供的其他 User 身份。

五、現實時間與劇情時間
裝置日期、現實時間與消息時間戳只供內部排序，不是劇情時間，也不得顯示給 User。只有正文中的明確日期、設定年份、相對時間或可由已知劇情時間直接推導的時間可寫入 occurred_on／story_time。沒有劇情時間時留空，date_basis 使用 unknown。

六、敘事層級
timeline 與 story_states 的 narrative_layer 只使用：mainline、flashback、dream、hypothetical、side_story。
mainline 是當前故事線真實發生的事件，只有它可直接更新當前場景、人物關係與現況。
flashback 是真實過去或回憶；可補充歷史與相遇起源，但不能寫成現在才發生，也不能恢復已結束的舊狀態。只有延續至今的後果可更新現況。
dream 與 hypothetical 不成為主線事實、不觸發不可逆事件，也不直接改變關係或身體狀態；只有其揭示持續動機或實際推動後續主線時，才保留造成的主線影響。
side_story 是番外、AU、劇中劇或與本線分離的片段。它保留在自身敘事層，不改寫 mainline；只有 User 明確宣告其屬於本故事線正式事實時，後續才可按 mainline 處理。

不可逆事件只指正文中已經發生，且無法撤回、恢復或否定的事實性事件。它必須有正文證據；計畫、預測、象徵物品、背景設定、夢境、回憶、假設或尚未發生的可能性，不屬於不可逆事件。一旦成立，後續摘要保留該事件及其影響；除非 User 明確進行劇情修正，不自行撤銷或改寫。

七、摘要範圍與區段
優先保留主線事件與重要選擇的因果、新角色與實際關聯、關係形成或改變原因、衝突、背叛、結盟、陣營變化、伏筆、懸念、未完成揭露、承諾與交易、重要物品地點及證據、持續內在改變、重大傷亡損失、明確時間推進、不可逆選擇、User 劇情偏好或修正，以及仍影響後續的支線結果。
忽略不影響後續的環境描寫、逐招動作、未變化背景、無因果作用的過渡對話、不影響劇情決策的 OOC、無新結果的重複事件，以及無持續後果的短暫感受。

summary 只使用非空的「### ——主線——」「### ——支線——」「### ——氛圍——」「### ——觀察區——」。
主線保存主要因果鏈、關鍵選擇、關係形成與重大轉折、不可逆事件及決定後續局勢的資訊。
支線保存具有獨立起因與發展、可能在後續併入主線的內容。
氛圍只保存會持續影響人物心理、關係基調或場景氣質的事實，不作為文學描寫收納區。
觀察區只保存未證實推測、互相衝突說法、動機未明的反常行為、作用未明的疑似伏筆、未能確認是否為同一人的名字，以及未有客觀證據的角色聲稱。觀察區不是既定事實；對仍需在劇情中自然釐清的說法，明確記錄其未解衝突。

條目格式：
**[類別] 標題**
正文。
只有正文有劇情時間時才增加「[劇情位置] 劇情時間」。
類別可用：世界觀、角色、關係、伏筆、衝突、物品、地點、懸念、時間線、不可逆、User 偏好、情感暗線、陣營情報、死亡／損失、種族資料。

為完整 summary 建立 recall_segments：依閱讀順序編號，每段只覆蓋一個摘要段落；若單一段落含多個可獨立召回的事件，先在 summary 內按事件邊界拆段。content 必須是 summary 中連續且完全相同的原文。keywords 只輸出一個，使用能在後續正文中命中該事件的具體行動、結果、轉折、物品、地點或關聯對象；優先寫「對象＋事件／結果」或具有唯一辨識力的具體事件詞。只用人物姓名、稱謂、代詞、泛用情緒或抽象主題無法辨認事件。近義詞只保留辨識度最高的一個，段與段之間避免重複。

八、內容與去重
使用中性客觀第三人稱，不輸出第一人稱、前言、自我介紹、結語或對 User 的建議。使用具體事件，不用抽象文學語句代替實際原因。可以調整語序，但保持行動主體、先後、因果與立場。
同一事件、關係轉折或身份對照在完整 summary 中只保留一份；新進展更新原條目。兩份既有卷宗中的重複事件先合併，不重複堆疊。已被覆蓋的舊現況只保留持續影響；已結束且不再牽動後續的支線可從當前 summary 移除，交由其已儲存的 recall_segments 在需要時召回。兌現承諾只在其結果仍改變關係或局勢時保留。既有標題不是必須永久保留的清單；根據當前劇情節點保留主線因果、仍活著的支線及後續仍會使用的結果。

若【摘要來源範圍】指向既有摘要，將該摘要視為本次修訂目標：讀取其內容與來源正文，輸出同一範圍的完整替換版本，不把修訂內容追加成新的獨立事件。保留原本的故事線位置與仍有效的因果；只有本次正文證明已變更的部分才更新。程式會負責保存 revision、來源範圍與依賴關係。

九、相遇、靠近、多身份與逐對關係
主要人物之間長期保留初次相遇的劇情時間、地點、情境、雙方當時身份、初始態度、第一次靠近的具體事件、重要轉折原因、當前關係及未解阻力。後續親密行為不能覆蓋相遇起源與靠近契機；資料沒有提供時標記未明。

每個人物使用唯一穩定 entity_id。既有人物必須沿用系統提供的 entity_id；新人物輸出 new，由程式發號。偽名、藝名、官面身份、合法新名、婚後稱謂、暱稱與封號掛在同一人物下。只有正文證據明確指出兩個名字屬於同一人時才能合併；名字形式相似不是同一人的證據。不得自行縮寫或改寫姓名。
每個 identities 子項保存名字、身份類型、用途、開始使用的劇情時間、適用場合、公開程度、哪些人物知道其屬於同一人，以及來源證據。摘要正文依場景使用合理稱呼；story_characters.name 始終是穩定錨點名。

身份揭露保存揭露者、對象、證據、在場反應，以及被指控、懷疑、聽說、調查中、已相信、已證實或官方承認的認知階段。某人喊出真名不代表其他人相信、完整知情、公開身份失效或法律身份被推翻。旁白、摘要、User 或單一角色知道的內容不向其他人物自動擴散。

多伴侶與多段關係必須逐對保存。A↔B 的相識起源、靠近契機、稱呼、承諾、親密史、共享秘密、衝突、公開狀態及身份知情程度不能移植到其他配對；群體場景也不合併成集體關係。公開狀態的 knowledge_scope 只列正文可證明的已知情人物。

親密互動只按其對關係或劇情造成的實質影響記錄，不描述身體過程，不用渲染性措辭。沒有新轉折的重複場景不新增條目；可更新逐對關係現況。除非造成承諾、決裂、懷孕、受傷、背叛或其他重要轉折，不單獨佔據主線條目。

十、身體與疊加狀態
持續傷勢、中毒、疾病、懷孕、流產、殘疾、疤痕、失明、截肢、持續外貌改變及必須長期攜帶的輔具，寫入 story_states，不修改原始角色卡。body 狀態只使用 permanent、recovering、healed；痊癒時覆蓋原狀態並保留歷史事件。沒有持續後果的短暫疲憊、疼痛、情緒或生理感受隨場景結束失效。

假身份、假婚姻、假孕、誘餌、臥底或弄假成真，分開保存客觀事實、公開說法、私下計畫、各人物相信版本及客觀證實程度。對外宣稱不等於已經發生；沒有正式確認或客觀證據時，不把計畫、偽裝或感受寫成已確診事實。

十一、story_states
state_key 命名：scene.current；promise.{entity_id}.{slug}；body.{entity_id}.{slug}；identity.{entity_id}.{slug}；knowledge.{知情者 entity_id}.{被認知者 entity_id}.{slug}；plot.{slug}；item.{entity_id}.{slug}。slug 短且穩定；更新既有狀態時沿用既有 key。
同一件事（同一傷病、同一身分、同一約定）優先沿用【現有劇情狀態】裡的 state_key。只有在必須改用新 key 時，才在 replaces_state_keys 填入被取代的舊 key（最多 3 個）；不同的傷病或不同的事不得互相取代。
scene.current 保存當前地點、在場人物、正在進行的行動或對話、尚未回答的話、未完成動作及直接影響下一段的條件。只有場景或接續點實際改變時輸出 scene.current；沒有改變或只有 OOC 時不輸出，由程式沿用舊值。
若【現有劇情狀態】中的計畫、承諾、任務或場景在本輪已完成、取消、違背、停滯或被新行動取代，必須沿用原 state_key 輸出其最新終止狀態；不能只新增後續事件而讓舊狀態繼續保持 active／pending。scene.current 只描述本輪結束時真正所在的位置與接續點，已經執行完的「準備前往／即將處理」不得殘留其中。
promise status 只使用 pending、fulfilled、broken、cancelled。
body status 只使用 permanent、recovering、healed。
identity status 只使用 active、suspended、revoked、unknown。
knowledge status 只使用 unaware、suspicious、heard、investigating、believed、confirmed。
plot status 只使用 active、resolved、stalled。
item status 只使用 held、lost、destroyed、transferred、unknown。
scene 的 status 必須為空字串。每輪 story_states 最多 12 條；只輸出本輪新增或有實質變化的狀態。

十二、timeline、人物與關係輸出
timeline 只提取本輪新增、明確修正或正式收束的離散事件，每輪最多 8 條。保留真正主體、敘事層級、劇情時間、有效消息 ID 與逐字 evidence；同一事件不重複建立。
character_index 是人物落庫的精簡保險索引，必須在 summary 前先輸出。逐一核對本輪正文中具名人物與【現有人物】；凡正文明確寫出姓名、但現有人物中沒有該姓名或別名者，都輸出一筆，最多 24 筆。即使此人在故事時間上早已登場，也要補列，不能因「不是首次登場」而略過。每筆只寫 entity_id、name、source_message_ids、evidence；不得收錄只有職稱或親屬稱呼而沒有姓名的人物。已有完整 story_characters 項目的人仍可出現在索引中，程式會合併。
story_characters 每輪最多 24 個，只輸出首次出場，或本輪獲得新身份、別名、外貌、性格、立場、動機、陣營、身份對照修正的人物。先輸出首次出場的新人物，再輸出既有人物更新；若候選超過 24 個，按首次出場順序保留新人物。證據不足的欄位填「不明」，不依職位或劇情需要補完。
本輪正文中首次出現且可辨認的命名人物，必須輸出一筆 story_characters；即使只知道名字與出場情境，也先以 new 建檔，其餘欄位填「不明」。只有該姓名確實屬於【本輪命中的既有人物】中某個 entity_id 時才可沿用該 ID；新人物一律輸出 entity_id="new"。source_message_ids 與 evidence 必須指向首次出場的正文證據。
relationships 使用 entity_id 配對，每輪最多 8 條。origin 只保存最早相遇或最初建立關聯的原因；既有非空 origin 原樣保留，除非 User 明確修正。後續靠近、決裂、和好、背叛、結盟、身份揭露及關係公開寫入 change，並保留造成變化的具體事件。

十三、summary 長度
summary 必須不超過 {{rp_summary_max_chars}} 個中文字。這是儲存硬上限，不是目標；不必寫滿，正確性優先。接近上限時，根據當前劇情節點優先保留主線因果、決定後續的支線、關係轉折原因與仍未解決的線索；依序壓縮或移除無後續作用的氛圍、已結束支線、已兌現承諾、被覆蓋舊現況與已收束過程。
相遇起源、靠近契機、轉折原因、未解衝突、未回收伏筆、待兌現承諾、身份對照、知情邊界、持續身體狀態與當前接續點，只在仍可能被後續劇情牽動時優先保留。不可逆事件若仍是當前因果鏈的重要節點，壓縮為一段內的一至兩句，保留主體、必要原因、結果與持續影響；無持續影響時不必因「不可逆」標籤而永久保留。

十四、輸出
只輸出一個合法 JSON 物件，不要 code fence、前言、分析或結語。JSON 必須正確跳脫換行、雙引號與反斜線。沒有候選的陣列輸出空陣列。summary 不得為空。storyline_id 原樣返回【當前故事線】ID。

輸出 schema：
{
  "storyline_id":"當前故事線 ID",
  "character_index":[{"entity_id":"既有 P-0001 或 new","name":"正文明確姓名","source_message_ids":[1],"evidence":"含該姓名的逐字原文"}],
  "summary":"完整替換版劇情卷宗 Markdown",
  "recall_segments":[{"segment_order":1,"title":"具體事件短標題","content":"逐字複製自 summary 的一個段落","keywords":["唯一的高辨識度事件詞"]}],
  "timeline":[{"event_key":"穩定事件識別；新事件可留空","narrative_layer":"mainline|flashback|dream|hypothetical|side_story","subject_entity_ids":["P-0001"],"source_message_ids":[1],"occurred_on":"劇情時間或空字串","date_basis":"explicit|relative|unknown","value":"事件","evidence":"逐字原文"}],
  "story_states":[{"state_key":"穩定 key","replaces_state_keys":[],"state_type":"scene|promise|body|identity|knowledge|plot|item","subject_entity_key":"P-0001 或空字串","object_entity_key":"P-0002 或空字串","narrative_layer":"mainline|flashback|dream|hypothetical|side_story","value":"當前狀態","status":"與 state_type 對應的合法值或空字串","story_time":"劇情時間或空字串","source_message_ids":[1],"evidence":"逐字原文"}],
  "story_characters":[{"entity_id":"既有 P-0001 或 new","name":"穩定錨點名","aliases":["其他明確名稱"],"identities":[{"name":"身份名稱","identity_type":"身份類型","purpose":"用途","started_at":"劇情時間或空字串","applicable_context":"適用場合","visibility":"公開程度","known_by":[{"entity_id":"P-0002","status":"suspicious|heard|investigating|believed|confirmed"}],"source_message_ids":[1],"evidence":"逐字原文"}],"gender":"性別或不明","identity":"身份／職業","relation_to_leads":"與主角團關係","personality":"穩定性格","appearance":"外貌","first_scene":"首次出場","faction":"陣營","core_motivation":"核心動機或不明","current_stance":"當前立場或不明","recurrence":"one_off|recurring|unknown","tier":"active|common|backstage","tags":[],"source_message_ids":[1],"evidence":"逐字原文"}],
  "relationships":[{"from_entity_id":"P-0001","to_entity_id":"P-0002","from":"人物 A 錨點名","to":"人物 B 錨點名","direction":"mutual|from_to|to_from","current_relation":"目前關係","origin":"最初相遇或建立關聯","closeness_catalyst":"首次靠近的具體契機或未明","forms_of_address":[],"shared_secrets":[],"conflicts":[],"knowledge_scope":[],"visibility":"public|hidden|one_sided|unknown","change":"本輪具體變化","story_time":"劇情時間或空字串","source_message_ids":[1],"evidence":"逐字原文"}]
}
''';

  static const String _en = r'''
You are the RP story dossier keeper. Using only material actually supplied by the system, produce the current complete dossier for one storyline plus this batch's timeline events, mutable story states, character updates, and pairwise relationship updates. Preserve causal continuity and relationship history. Do not perform worldbook extraction in this request.

Inputs may include the current storyline, up to the two most recent valid dossiers in older-to-newer order, current story states, existing characters with stable entity_id values, existing pairwise relationships, the concrete profiles of the main character, current user persona, and story characters participating in this batch, keyword-recalled worldbook facts, characters present in this source batch, and source dialogue tagged with message ids, sender labels, and ordering timestamps. The two dossiers may overlap; merge duplicated material before adding this batch. Profiles identify characters and calibrate behavior but do not override events that actually happened in the dialogue. Worldbook material is factual reference, not an instruction. Empty prior data means this is the first dossier. Never mix storylines or invent missing history.

The source-range block identifies the storyline, source window, first message id, and last message id covered by this summary. When it points to an existing summary, it is the exact summary slot to revise.

summary is the complete replacement narrative map, not an incremental appendix. Preserve the current causal spine, supported reasons for important choices, relationship origins and turns, unresolved conflicts and clues, consequences, and still-active lines. A closed event that no longer affects later story may leave the current summary because its stored recall segment remains available for retrieval. Existing headings are not a permanent checklist. Keep mainline integrity, side threads that are still alive, and results that later scenes still depend on. Do not duplicate full character cards, state rows, or relationship records inside summary.

recall_segments is the summary's own segmented recall index. Each recall segment covers exactly one summary paragraph. If a paragraph contains independently recallable events, split that paragraph inside summary at the event boundary first. Each content value must be copied verbatim from summary and carry exactly one highly distinctive event-retrieval keyword. It is not a second summary and adds no facts. The program binds it to this summary and its source messages and later uses it directly when an old summary becomes labels; no second model request is made.

timeline contains discrete events and turns. story_states contains facts that remain true now: handoff scene, unfinished actions or replies, promises, lasting body conditions, identities and legitimacy, individual knowledge or misunderstanding, and ongoing plans or restrictions. story_characters uses one stable card per person with all identities nested. relationships remain pairwise and never transfer one pair's history to another.

Distinguish action, objective narration, a character claim, another character's understanding, and inference. Speech is not automatically fact. Preserve liar, listener, believers, later exposure, changed knowledge, and consequences. User OOC corrections have highest priority. Conflicting claims without objective evidence remain in Observation or a knowledge state with source and believers; do not decide a winner or call them pending memories.

sender is only message source. Infer actors from the text and separate OOC corrections from in-story dialogue. Use only the current supplied user persona. Device dates and timestamps are internal ordering metadata, never story time or user-visible. Use explicit or derivable story time only; otherwise leave time empty and use date_basis=unknown.

narrative_layer is mainline, flashback, dream, hypothetical, or side_story. Only mainline changes current reality. A factual flashback may add history and lasting consequences but cannot reactivate ended states. Dreams and hypotheticals are not mainline facts and do not directly change relationships, body state, or irreversible events. side_story stays separate unless the user explicitly canonizes it.

An irreversible event is only a factual event that has already happened in the supplied story and cannot be undone, restored, or denied. Plans, predictions, symbolic objects, world settings, dreams, flashbacks, hypotheticals, and possible future outcomes are not irreversible events. Once supported by evidence, preserve the event and its consequences unless the user explicitly revises the story.

Use non-empty summary sections only: "### ——Main——", "### ——Side Threads——", "### ——Atmosphere——", and "### ——Observation——". Main stores the central causal chain, major turns, irreversible events, and decisive information. Side Threads stores independent lines that may later rejoin. Atmosphere stores only persistent psychological, relational, or scene facts. Observation stores unsupported claims, conflicting accounts, unexplained behavior, uncertain identity matches, and unresolved clues; it is not established fact.

Write neutral objective third person with concrete events. Preserve actor, order, causality, and stance. No preface, self-description, conclusion, advice, or literary abstraction in place of actual causes. Keep one copy of each event, relationship turn, and identity mapping; merge duplicated events from the two prior dossiers before adding developments. Preserve every closed line in at least one sentence containing its cause, result, and lasting effect. Keep an existing event title unchanged unless the user explicitly corrects that event, so the program can verify that rolling compression did not erase it.

Build recall_segments for the complete summary in reading order. Each segment covers exactly one paragraph; split a long paragraph inside summary at an event boundary when it contains independently recallable events. content must be an exact contiguous substring of summary. keywords must contain exactly one phrase identifying the concrete action, result, turn, object, place, or directly involved counterpart, preferably counterpart-plus-event/result or another uniquely identifying event phrase. A lone character name, title, pronoun, generic emotion, or abstract topic does not identify an event. From near-synonyms keep only the most distinctive phrase and do not reuse it across segments.

If the source-range block points to an existing summary, treat that summary as the revision target. Read its content together with the supplied source dialogue and output a complete replacement for the same range; do not append the revision as a new independent event. Preserve its storyline position and still-valid causality, and update only what the supplied evidence changes. The program stores the revision, source range, and dependent-summary relationships.

Always preserve lead meeting origin, identities at meeting, initial stance, first concrete closeness catalyst, reasons for major turns, current relation, and unresolved obstacles. Later intimacy cannot overwrite origin or catalyst. Mark absent early evidence as unknown.

Each person has one stable entity_id. Reuse supplied ids; output new for a new person and let the program issue it. Merge names only when evidence explicitly proves one person; similar names are not proof. Nest legal names, aliases, disguises, titles, married styles, and stage names under identities with purpose, start time, context, visibility, per-person knowledge, source ids, and exact evidence.

Keep every relationship pair separate, including origin, closeness catalyst, forms of address, shared secrets, visibility, conflicts, knowledge scope, and turns. Record intimacy only through concrete plot or relationship effect, without bodily process or sensational language. Repetition with no new turn creates no new item.

Lasting injury, illness, pregnancy, miscarriage, disability, scar, blindness, amputation, appearance change, or required aid belongs to story_states, not the base card. body status is permanent, recovering, or healed. Transient fatigue, pain, emotion, and sensation expire unless they create lasting consequence. Separate objective fact, public claim, private plan, each person's belief, and confirmation for layered deceptions.

state_key forms: scene.current; promise.{entity_id}.{slug}; body.{entity_id}.{slug}; identity.{entity_id}.{slug}; knowledge.{observer entity_id}.{subject entity_id}.{slug}; plot.{slug}; item.{entity_id}.{slug}. Reuse keys. Emit scene.current only when the scene or exact handoff changed; otherwise the program retains it. Status: promise=pending|fulfilled|broken|cancelled; body=permanent|recovering|healed; identity=active|suspended|revoked|unknown; knowledge=unaware|suspicious|heard|investigating|believed|confirmed; plot=active|resolved|stalled; item=held|lost|destroyed|transferred|unknown; scene uses empty status. Emit at most 12 changed states.
Reuse an existing state_key for the same condition/identity/promise. Only if you must use a new key, list the old keys it replaces in replaces_state_keys (max 3). Never let different conditions replace each other.
When a supplied plan, promise, task, or scene state was completed, cancelled, broken, stalled, or superseded in this batch, emit the same state_key with its terminal/current status. Do not merely add a later event while leaving the earlier active/pending state alive. scene.current describes the actual location and handoff at the end of this batch; an already-executed "about to leave/prepare to investigate" step cannot remain in it.

Emit at most 8 new, corrected, or closed timeline events; 24 changed characters; and 8 changed pairwise relationships. Prioritize first-appearance character records before updates to existing characters. If more than 24 character candidates exist, keep new characters in first-appearance order. Each item cites supplied source_message_ids and exact evidence. Preserve a non-empty relationship origin unless the user corrects it. Later closeness, rupture, reconciliation, betrayal, alliance, identity exposure, or public disclosure belongs in change.
character_index is the compact persistence safety index and must be emitted before summary. Compare every explicitly named person in this source batch against the supplied existing-character roster. Emit every name that is absent from that roster or its aliases, even when the person is already long-established in story chronology rather than making a first chronological appearance. Each of at most 24 items contains only entity_id, name, source_message_ids, and exact evidence. Do not index unnamed titles or kinship labels. A person may also have a full story_characters item; the program merges them.
Every identifiable named person appearing for the first time in this batch must produce one story_characters item. Even when only the name and entrance scene are known, output entity_id=new, use unknown for unsupported fields, and cite the first-appearance message id and exact evidence. Reuse an existing entity_id only when that exact person and name are present in the supplied existing-character list; the supplied matched-existing list is not exhaustive of people in the source dialogue.

The summary must not exceed {{rp_summary_max_chars}} characters. This is a hard storage ceiling, not a target. Near it, preserve the current main causal chain, side threads that determine later events, relationship-turn causes, and unresolved lines. Compress or remove inactive atmosphere, closed side lines, fulfilled promises, superseded conditions, and closed process detail in that order. Meeting origins, closeness catalysts, turn causes, unresolved conflicts or clues, pending promises, identity mappings, knowledge boundaries, continuing body states, and the current handoff receive priority only while they can still affect later story. If an irreversible event remains an important node in the current causal chain, condense it to one or two sentences in a single paragraph with its actor, necessary cause, result, and lasting effect. Irreversibility alone does not make an event permanent when it has no continuing effect.

Output exactly one valid JSON object with escaped newlines, quotes, and backslashes. No code fence, preface, analysis, or conclusion. Empty candidates use empty arrays. summary must not be empty. Return storyline_id exactly as supplied.

Schema:
{"storyline_id":"current id","character_index":[{"entity_id":"existing P-0001 or new","name":"explicit source name","source_message_ids":[1],"evidence":"exact source containing the name"}],"summary":"complete replacement dossier Markdown","recall_segments":[{"segment_order":1,"title":"concrete event label","content":"one paragraph copied verbatim from summary","keywords":["one highly distinctive event phrase"]}],"timeline":[{"event_key":"stable id or empty for new","narrative_layer":"mainline|flashback|dream|hypothetical|side_story","subject_entity_ids":["P-0001"],"source_message_ids":[1],"occurred_on":"story time or empty","date_basis":"explicit|relative|unknown","value":"event","evidence":"exact source"}],"story_states":[{"state_key":"stable key","replaces_state_keys":[],"state_type":"scene|promise|body|identity|knowledge|plot|item","subject_entity_key":"P-0001 or empty","object_entity_key":"P-0002 or empty","narrative_layer":"mainline|flashback|dream|hypothetical|side_story","value":"current state","status":"legal status or empty","story_time":"story time or empty","source_message_ids":[1],"evidence":"exact source"}],"story_characters":[{"entity_id":"existing P-0001 or new","name":"stable anchor","aliases":[],"identities":[{"name":"identity name","identity_type":"type","purpose":"purpose","started_at":"story time or empty","applicable_context":"context","visibility":"visibility","known_by":[{"entity_id":"P-0002","status":"suspicious|heard|investigating|believed|confirmed"}],"source_message_ids":[1],"evidence":"exact source"}],"gender":"gender or unknown","identity":"identity or occupation","relation_to_leads":"relation","personality":"stable traits","appearance":"appearance","first_scene":"first scene","faction":"faction","core_motivation":"motive or unknown","current_stance":"stance or unknown","recurrence":"one_off|recurring|unknown","tier":"active|common|backstage","tags":[],"source_message_ids":[1],"evidence":"exact source"}],"relationships":[{"from_entity_id":"P-0001","to_entity_id":"P-0002","from":"A anchor","to":"B anchor","direction":"mutual|from_to|to_from","current_relation":"current relation","origin":"first meeting or connection","closeness_catalyst":"first concrete catalyst or unknown","forms_of_address":[],"shared_secrets":[],"conflicts":[],"knowledge_scope":[],"visibility":"public|hidden|one_sided|unknown","change":"concrete update","story_time":"story time or empty","source_message_ids":[1],"evidence":"exact source"}]}.
''';
}
