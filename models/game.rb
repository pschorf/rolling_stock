require './models/base'
require './models/share_price'

class Game < Base
  many_to_one :user

  PHASE_NAME = {
    1 => 'Issue New Shares',
    2 => 'Form Corporations',
    3 => 'Auctions And Share Trading',
    4 => 'Determine New Player Order',
    5 => 'Foreign Investor Buys Companies',
    6 => 'Corporations Buys Companies',
    7 => 'Close Companies',
    8 => 'Collect Income',
    9 => 'Pay Dividends And Adjust Share Prices',
    10 => 'Check Game End',
  }.freeze

  attr_reader(
    :stock_market,
    :available_corportations,
    :corporations,
    :companies,
    :pending_companies,
    :company_deck,
    :all_companies,
    :round,
    :phase,
  )

  def self.empty_game user
    Game.create(
      user: user,
      users: [user.id],
      version: '1.0',
      settings: '',
      state: 'new',
      deck: [],
    )
  end

  def load
    @stock_market = SharePrice.initial_market
    @available_corportations = Corporation::CORPORATIONS.dup
    @corporations = {}
    @companies = [] # available companies
    @pending_companies = []
    @company_deck = []
    @all_companies = Company::COMPANIES.map { |sym, params| [sym, Company.new(self, sym, *params)] }.to_h
    @current_bid = nil
    @foreign_investor = ForeignInvestor.new
    @round = 1
    @phase = 1
    @cash = 0
    @end_game_card = :penultimate
    setup_deck
    draw_companies
    untap_pending_companies
    step
  end

  def players
    @_players ||= User
      .where(id: users.to_a)
      .map { |user| [user.id, Player.new(user.id, user.name)] }
      .to_h
  end

  def new_game?
    state == 'new'
  end

  def active?
    state == 'active'
  end

  def finished?
    state == 'finished'
  end

  def phase_name
    PHASE_NAME[@phase]
  end

  def active_entity
    case @phase
    when 1, 7, 9
      active_corporation
    when 2
      active_company
    when 3
      active_player
    end
  end

  def step
    current_phase = @phase

    case @phase
    when 1
      check_phase_change @corporations.values.reject { |c| c.shares.empty? }
    when 2
      check_phase_change players.values.flat_map(&:companies)
    when 3
      check_no_player_purchases
    when 4
      new_player_order
    when 5
      foreign_investor_purchase
    when 6
      check_no_company_purchases
    when 7
      check_phase_change(@corporations.values ++ players.values)
    when 8
      @phase += 1
    when 9
      check_phase_change @corporations.values.reject { |c| c.cash.zero? }
    when 10
      check_end
    end

    step if @phase != current_phase
  end

  def process_action
  end

  def process_action_data data
    send "process_phase_#{@phase}", data
  end

  # phase 1
  def process_phase_1 data
    corporation = @corporations[data[:corporation]]
    corporation.pass
    issue_share corporation unless data[:pass]
    check_phase_change @corporations.values.reject { |c| c.shares.empty? }
  end

  def issue_share corporation
    raise unless corporation.can_issue_share?
    corporation.issue_share
    check_bankruptcy corporation
  end

  # phase 2
  def process_phase_2 data
    company = @all_companies[data[:company]]
    company.pass

    unless data[:pass]
      share_price = @stock_market.find { |sp| sp.price == data[:price] }
      corporation = data[:corporation]
      form_corporation company, share_price, corporation
    end

    check_phase_change players.flat_map(&:companies)
  end

  def form_corporation company, share_price, corporation_name
    raise unless @available_corportations.include? corporation_name
    raise unless share_price.valid_range? company
    @available_corportations.remove corporation_name
    @corporations[corporation_name] = Corporation.new corporation_name, company, share_price
  end

  # phase 3
  def process_phase_3 data
    player = players[data[:player]]

    case data[:action]
    when 'pass'
      player.pass
    when 'auction'
      company = @companies.find { |c| c.name == data[:company] }
      auction_company player, company, data[:price]
      player.unpass
    when 'buy'
      buy_share player, data[:corporation]
      player.unpass
    when 'sell'
      sell_share player, data[:corporation]
      player.unpass
    end
  end

  def buy_share player, corporation
    raise unless corporation.can_buy_share?
    corporation.buy_share player
  end

  def sell_share player, corporation
    raise unless corporation.can_sell_share? player
    corporation.sell_share player
    check_bankruptcy corporation
  end

  def auction_company player, company, price
    @current_bid = Bid.new player, company, price
  end

  def finalize_auction
    company = @current_bid.company
    @current_bid.player.buy_company company, @current_bid.price
    draw_companies
  end

  # phase 4
  def new_player_order
    untap_pending_companies
    players.sort_by(&:cash).reverse!
    @phase += 1
  end

  # phase 5
  def foreign_investor_purchase
    @foreign_investor.purchase_companies @companies
    draw_companies
    untap_pending_companies
    @phase += 1
  end

  # phase 6
  def process_phase_6 data
    corporation = @corporations[data[:corporation]]

    if data[:pass]
      corporation.pass
    else
      company = @all_companies[data[:company]]
      buy_company corporation, company, data[:price]
    end
  end

  def buy_company corporation, company, price
    raise unless company.valid_price? price
    corporation.buy_company company, price
  end

  # phase 7
  def process_phase_7 data
    holder = @corporations[data[:corporation]] || players[data[:player]]

    if data[:pass]
      holder.pass
    else
      company = @all_companies[data[:company]]
      close_company holder, company
    end
  end

  def close_company holder, company
    holder.close_company company
  end

  # phase 8
  def collect_income
    tier = cost_of_ownership_tier
    (@corporations.values + players.values).each do |entity|
      entity.collect_income tier
    end
  end

  # phase 9
  def process_phase_7 data
    corporation = @corporations[data[:corporation]]
    corporation.pass
    pay_dividend corporation, data[:amount]
  end

  def pay_dividend corporation, amount
    corporation.pay_dividend amount, players.values
    check_bankruptcy corporation
  end

  # phase 10
  def check_end
    @phase += 1
    @eng_game_card = :last_turn if cost_of_ownership_tier == :penultimate
    cost_of_ownership_tier == :last_turn || @stock_market.last.nil?
  end

  private

  def setup_deck
    if deck.size.zero?
      groups = @all_companies.values.group_by &:tier

      Company::TIERS.each do |tier|
        num_cards = players.size + 1
        num_cards = 6 if tier == :orange && players.size == 4
        num_cards = 8 if tier == :orange && players.size == 5
        @company_deck.concat(groups[tier].shuffle.take num_cards)
      end

      update deck: @company_deck.map(&:symbol)
    else
      @company_deck = deck.map { |sym| Company.new self, sym, *Company::COMPANIES[sym] }
    end
  end

  def cost_of_ownership_tier
    if @company_deck.empty?
      @end_game_card
    else
      @company_deck.first.tier
    end
  end

  def active_corporation
    @corporations.values.sort_by(&:price).reverse.find &:active?
  end

  def active_company
    players.values.flat_map(&:companies).sort_by(&:value).reverse.find &:active?
  end

  def active_player
    players.values.find &:active?
  end

  def draw_companies
    @pending_companies.concat @company_deck.shift(players.size - @companies.size)
  end

  def untap_pending_companies
    @companies.concat @pending_companies.slice!(0..-1)
  end

  def check_phase_change passers
    return unless passers.all? &:passed?
    passers.each &:unpass
    @phase += 1
  end

  def check_no_player_purchases
    min = [
      @corporations.values.map { |c| c.next_share_price.price }.min,
      @companies.map(&:value).min,
    ].compact.min

    check_phase_change players.values.reject { |p| p.cash < min && p.shares.empty? }
  end

  def check_no_company_purchases
    min = [
      players.flat_map { |p| p.companies.map &:min_price }.min,
      @foreign_investor.companies.map(&:min_price).min,
    ].compact.min

    check_phase_change @corporations.values.reject { |c| c.cash < min }
  end

  def check_bankruptcy corporation
    return unless corporation.is_bankrupt?
    @corporations.remove corporation.name
    @available_corportations << corporation.name
    @players.each do |player|
      player.shares.reject! { |share| share.corporation == corporation }
    end
    @stock_market[corporation.share_price.index] = corporation.share_price
  end
end
