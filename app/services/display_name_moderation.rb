require "json"

# Evaluates participant display names with the TypeSafe Jev model via the
# OpenRouter Decisions API so inappropriate names (obscenity, slurs,
# impersonation, personal data, spam) are rejected before they appear on
# rankings and venue screens. Only the candidate name and the rubric are
# sent upstream; no other participant data leaves the server. Moderation
# is skipped when OPENROUTER_API_KEY is not configured, and provider
# failures are fail-open unless DISPLAY_NAME_MODERATION_FAIL_CLOSED is
# set, so an outage cannot take registration down with it.
class DisplayNameModeration
  # The same rubric is asked twice in one request — once in Japanese and
  # once in English — and the higher probability wins. Live probing showed
  # each language catches cases the other misses: Japanese reads masked
  # vulgarity (ま◯こ) better, English reads staff-impersonation (幹事,
  # 司会, kanri) and English slurs better.
  QUESTION_KEYS = %w[inappropriate_display_name_ja inappropriate_display_name_en].freeze

  INSTRUCTIONS_JA = "あなたはクイズ大会の表示名モデレーターです。参加者が入力した表示名が以下のいずれかに当てはまるか判定してください: " \
    "卑猥・下品な表現（性器・性行為・排泄物を直接指す語や卑語）、差別・ヘイトスピーチ・誹謗中傷（人種・属性への攻撃や、相手を罵倒する語）、 " \
    "暴力・犯罪・反社会的な示唆（殺害・暴力の予告、違法行為の宣伝、独裁者・テロリストの礼賛）、 " \
    "運営・主催者・スタッフ・他の参加者・有名人へのなりすまし（運営・管理者・公式を名乗るもの）、 " \
    "電話番号・メールアドレス・URL・SNS誘導などの個人情報や宣伝。 " \
    "卑語や禁止語の一部を○・◯・＊・記号・空白で伏せたり、当て字・ローマ字・ひらがな・カタカナに変換したりした回避表現も不適切です。 " \
    "当てはまれば不適切、どれにも当てはまらなければ適切です。"

  INSTRUCTIONS_EN = "You are a display-name moderator for a school quiz tournament. " \
    "Decide whether the submitted display name falls into any of these categories: " \
    "obscene or vulgar expressions (words directly referring to genitals, sexual acts, or excrement, including slurs), " \
    "discrimination/hate speech/personal attacks (attacks on race or attributes, insults directed at people), " \
    "violence/crime/antisocial hints (threats of killing or violence, advertising illegal acts, glorifying dictators or terrorists), " \
    "impersonation of the organizer, staff, another participant, or a celebrity (claiming to be management, an admin, or official), " \
    "personal information or promotion such as phone numbers, email addresses, URLs, or invitations to other social platforms. " \
    "Evasion spellings that mask banned words with symbols like circles, asterisks, spaces, or rewrite them via ateji, romaji, hiragana, or katakana are also inappropriate. " \
    "If any applies, the name is inappropriate; otherwise it is appropriate."

  CRITERIA_JA = {
    "true" => "不適切または不審な表示名であり、公表すべきでない",
    "false" => "一般的な表示名として公表して問題ない"
  }.freeze

  CRITERIA_EN = {
    "true" => "inappropriate or suspicious display name that should not be published",
    "false" => "ordinary display name acceptable to publish"
  }.freeze

  Verdict = Data.define(:probability) do
    def inappropriate?(threshold) = probability >= threshold
  end

  def initialize(config: DisplayNameModerationConfig.new, transport: DisplayNameModerationTransport.new, logger: Rails.logger)
    @config = config
    @transport = transport
    @logger = logger
  end

  # True when the name must be rejected. Provider failures never raise; they
  # resolve to the configured open/closed policy instead.
  def inappropriate?(display_name)
    return false unless config.enabled?

    verdict = evaluate(display_name)
    return config.fail_closed? if verdict.nil?

    verdict.inappropriate?(config.threshold)
  end

  private

  attr_reader :config, :transport, :logger

  def evaluate(display_name)
    response = transport.request(
      method: :post,
      url: config.api_url,
      headers: request_headers,
      json: request_body(display_name)
    )
    raise DisplayNameModerationTransport::Error unless response.status.between?(200, 299)

    Verdict.new(probability: parse_probability(response.body))
  rescue DisplayNameModerationTransport::Error, JSON::ParserError, KeyError, TypeError => error
    logger.warn("[display-name-moderation] evaluation skipped: #{error.class}")
    nil
  end

  def request_headers
    {
      "Accept" => "application/json",
      "Authorization" => "Bearer #{config.api_key}",
      "User-Agent" => "anabuki-event-display-name-moderation/1.0"
    }
  end

  def request_body(display_name)
    {
      "model" => config.model,
      "state" => "クイズ大会の参加者が入力した表示名: #{display_name}",
      "questions" => {
        "inappropriate_display_name_ja" => {
          "type" => "noul",
          "instructions" => INSTRUCTIONS_JA,
          "criteria" => CRITERIA_JA
        },
        "inappropriate_display_name_en" => {
          "type" => "noul",
          "instructions" => INSTRUCTIONS_EN,
          "criteria" => CRITERIA_EN
        }
      }
    }
  end

  def parse_probability(body)
    answers = JSON.parse(body).fetch("answers")
    QUESTION_KEYS.map { |key| noul_probability(answers.fetch(key)) }.max
  end

  def noul_probability(answer)
    probability = Float(answer.fetch("noul"), exception: false)
    raise TypeError, "invalid noul probability" unless probability&.between?(0, 1)

    probability
  end
end
