require './spec/spec_helper'

describe Game do
  let(:player) { Player.new 1, 'Test' }
  let(:company) { Company.new player, 'BME', 'Bergisch', :red, 1, 1, [] }
  let(:share_price) { SharePrice.initial_market[6] } # 10, 6
  let(:corporation) { Corporation.new 'Android', company, share_price, SharePrice.initial_market }
  let(:user) { create :user }
  subject { create :game }

  def mock_players num
    allow(subject).to receive(:players).and_return(
      num.times.map { |n| [n, Player.new(n, "player_#{n}")] }.to_h
    )
  end

  it 'should init' do
    expect(subject).not_to be_nil
  end

  describe '#load' do
    it 'should create deck for 3 players' do
      mock_players 3
      subject.load
      expect(subject.company_deck.size).to eq(21)
    end

    it 'should create deck with 4 players' do
      mock_players 4
      subject.load
      expect(subject.company_deck.size).to eq(27)
    end

    it 'should create deck with 5 players' do
      mock_players 5
      subject.load
      expect(subject.company_deck.size).to eq(33)
    end
  end

  context 'after load' do
    before :each do
      mock_players 4
      subject.load
    end

    describe '#check_end' do
      it 'should return true if any corporation share price is 100' do
        subject.stock_market[31] = nil
        expect(subject.check_end).to eq(true)
      end

      it 'should be the last card' do
        allow(subject).to receive(:cost_of_ownership_tier).and_return(:last_turn)
        expect(subject.check_end).to eq(true)
      end
    end

    describe '#collect_income' do
      it 'should increase cash for corporations and players' do
        player.companies << company
        allow(subject).to receive(:players).and_return(player.id => player)
        expect { subject.collect_income }.to change { player.cash }.by 1
      end
    end

    describe '#issue_share' do
      it 'increase corp cash by 9' do
        expect { subject.issue_share corporation }.to change { corporation.cash }.by 9
      end
    end
  end
end
