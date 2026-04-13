#[test_only]
module english_auction::english_auction_test;
use english_auction::english_auction;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario;
use sui::clock;

const ADMIN: address = @0xAD;
const USER1: address = @0xB0;
const USER2: address = @0xC0;
const USER3: address = @0xD0;

const RESERVE_PRICE: u64 = 1_000_000_000;       // 1 SUI
const MIN_INCREMENT: u64 = 500_000_000;         // 0.5 SUI
const TOKEN_AMOUNT: u64 = 1_000_000_000_000;    // 1M tokens
const DURATION_MS: u64 = 3_600_000;             // 1 hour

fun mint_sui(amount: u64, ctx: &mut sui::tx_context::TxContext): coin::Coin<SUI> {
    let mut treasury = coin::create_treasury_cap_for_testing<SUI>(ctx);
    let c = coin::mint(&mut treasury, amount, ctx);
    sui::transfer::public_transfer(treasury, ctx.sender());
    c
}

#[test]
fun test_start_auction() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = scenario.ctx();

    let treasury = coin::create_treasury_cap_for_testing<english_auction::ENGLISH_AUCTION>(ctx);
    english_auction::create_for_testing(treasury, ctx);

    scenario.next_tx(ADMIN);
    let mut auction = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let cap = test_scenario::take_from_sender<english_auction::AdminCap>(&mut scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk, 0);
    english_auction::start_auction(&cap, &mut auction, RESERVE_PRICE, MIN_INCREMENT, TOKEN_AMOUNT, DURATION_MS, &clk);
    assert!(english_auction::state(&auction) == 1); // ACTIVE
    test_scenario::return_to_sender(&mut scenario, cap);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(auction);

    scenario.end();
}

#[test]
fun test_bidding_and_winner() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = scenario.ctx();

    let treasury = coin::create_treasury_cap_for_testing<english_auction::ENGLISH_AUCTION>(ctx);
    english_auction::create_for_testing(treasury, ctx);

    // Start auction at t=0
    scenario.next_tx(ADMIN);
    let mut auction = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let cap = test_scenario::take_from_sender<english_auction::AdminCap>(&mut scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk, 0);
    english_auction::start_auction(&cap, &mut auction, RESERVE_PRICE, MIN_INCREMENT, TOKEN_AMOUNT, DURATION_MS, &clk);
    test_scenario::return_to_sender(&mut scenario, cap);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(auction);

    // User1 bids 2 SUI (meets reserve)
    scenario.next_tx(USER1);
    let mut auction1 = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let pay1 = mint_sui(2_000_000_000, scenario.ctx());
    english_auction::bid(&mut auction1, pay1, scenario.ctx());
    assert!(english_auction::highest_bid(&auction1) == 2_000_000_000);
    assert!(english_auction::highest_bidder(&auction1) == USER1);
    assert!(english_auction::bid_count(&auction1) == 1);
    test_scenario::return_shared(auction1);

    // User2 bids 3 SUI (>= 2 + 0.5)
    scenario.next_tx(USER2);
    let mut auction2 = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let pay2 = mint_sui(3_000_000_000, scenario.ctx());
    english_auction::bid(&mut auction2, pay2, scenario.ctx());
    assert!(english_auction::highest_bid(&auction2) == 3_000_000_000);
    assert!(english_auction::highest_bidder(&auction2) == USER2);
    assert!(english_auction::bid_count(&auction2) == 2);
    test_scenario::return_shared(auction2);

    // User3 bids 5 SUI (>= 3 + 0.5)
    scenario.next_tx(USER3);
    let mut auction3 = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let pay3 = mint_sui(5_000_000_000, scenario.ctx());
    english_auction::bid(&mut auction3, pay3, scenario.ctx());
    assert!(english_auction::highest_bid(&auction3) == 5_000_000_000);
    assert!(english_auction::highest_bidder(&auction3) == USER3);
    assert!(english_auction::bid_count(&auction3) == 3);
    test_scenario::return_shared(auction3);

    // End auction at t > duration
    scenario.next_tx(ADMIN);
    let mut auction4 = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let cap2 = test_scenario::take_from_sender<english_auction::AdminCap>(&mut scenario);
    let mut clk2 = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk2, 4_000_000);
    english_auction::end_auction(&cap2, &mut auction4, &clk2);
    assert!(english_auction::state(&auction4) == 2); // ENDED
    assert!(english_auction::highest_bidder(&auction4) == USER3);
    test_scenario::return_to_sender(&mut scenario, cap2);
    clock::destroy_for_testing(clk2);
    test_scenario::return_shared(auction4);

    // Winner (User3) claims tokens
    scenario.next_tx(USER3);
    let mut auction5 = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let token = english_auction::claim(&mut auction5, scenario.ctx());
    assert!(coin::value(&token) == TOKEN_AMOUNT);
    sui::transfer::public_transfer(token, test_scenario::sender(&mut scenario));
    test_scenario::return_shared(auction5);

    // User1 (loser) withdraws deposit
    scenario.next_tx(USER1);
    let mut auction6 = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let refund1 = english_auction::withdraw_losing_bid(&mut auction6, scenario.ctx());
    assert!(coin::value(&refund1) == 2_000_000_000);
    sui::transfer::public_transfer(refund1, test_scenario::sender(&mut scenario));
    test_scenario::return_shared(auction6);

    // User2 (loser) withdraws deposit
    scenario.next_tx(USER2);
    let mut auction7 = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let refund2 = english_auction::withdraw_losing_bid(&mut auction7, scenario.ctx());
    assert!(coin::value(&refund2) == 3_000_000_000);
    sui::transfer::public_transfer(refund2, test_scenario::sender(&mut scenario));
    test_scenario::return_shared(auction7);

    scenario.end();
}

#[test]
#[expected_failure(abort_code = english_auction::EBidTooLow)]
fun test_bid_below_reserve() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = scenario.ctx();

    let treasury = coin::create_treasury_cap_for_testing<english_auction::ENGLISH_AUCTION>(ctx);
    english_auction::create_for_testing(treasury, ctx);

    // Start auction
    scenario.next_tx(ADMIN);
    let mut auction = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let cap = test_scenario::take_from_sender<english_auction::AdminCap>(&mut scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk, 0);
    english_auction::start_auction(&cap, &mut auction, RESERVE_PRICE, MIN_INCREMENT, TOKEN_AMOUNT, DURATION_MS, &clk);
    test_scenario::return_to_sender(&mut scenario, cap);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(auction);

    // Try to bid below reserve price (0.5 SUI < 1 SUI reserve)
    scenario.next_tx(USER1);
    let mut auction2 = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let pay = mint_sui(500_000_000, scenario.ctx());
    english_auction::bid(&mut auction2, pay, scenario.ctx());
    test_scenario::return_shared(auction2);

    scenario.end();
}

#[test]
#[expected_failure(abort_code = english_auction::ECannotOutbidSelf)]
fun test_cannot_outbid_self() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = scenario.ctx();

    let treasury = coin::create_treasury_cap_for_testing<english_auction::ENGLISH_AUCTION>(ctx);
    english_auction::create_for_testing(treasury, ctx);

    // Start auction
    scenario.next_tx(ADMIN);
    let mut auction = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let cap = test_scenario::take_from_sender<english_auction::AdminCap>(&mut scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk, 0);
    english_auction::start_auction(&cap, &mut auction, RESERVE_PRICE, MIN_INCREMENT, TOKEN_AMOUNT, DURATION_MS, &clk);
    test_scenario::return_to_sender(&mut scenario, cap);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(auction);

    // User1 bids 2 SUI
    scenario.next_tx(USER1);
    let mut auction2 = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let pay1 = mint_sui(2_000_000_000, scenario.ctx());
    english_auction::bid(&mut auction2, pay1, scenario.ctx());
    test_scenario::return_shared(auction2);

    // User1 tries to outbid themselves
    scenario.next_tx(USER1);
    let mut auction3 = test_scenario::take_shared<english_auction::EnglishAuctionRound>(&scenario);
    let pay2 = mint_sui(5_000_000_000, scenario.ctx());
    english_auction::bid(&mut auction3, pay2, scenario.ctx());
    test_scenario::return_shared(auction3);

    scenario.end();
}
