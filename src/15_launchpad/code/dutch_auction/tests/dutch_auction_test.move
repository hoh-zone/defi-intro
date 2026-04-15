#[test_only]
module dutch_auction::dutch_auction_test;

use dutch_auction::dutch_auction;
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario;

const ADMIN: address = @0xAD;
const USER1: address = @0xB0;
const USER2: address = @0xC0;

// Price per base unit (with 9 decimals):
// 10 MIST/base ≈ 10 SUI/token, 2 MIST/base ≈ 2 SUI/token
const START_PRICE: u64 = 10;
const END_PRICE: u64 = 2;
const DURATION_MS: u64 = 3_600_000;
const TOTAL_SUPPLY: u64 = 1_000_000_000_000;

fun mint_sui(amount: u64, ctx: &mut sui::tx_context::TxContext): coin::Coin<SUI> {
    let mut treasury = coin::create_treasury_cap_for_testing<SUI>(ctx);
    let c = coin::mint(&mut treasury, amount, ctx);
    sui::transfer::public_transfer(treasury, ctx.sender());
    c
}

#[test]
fun test_start_and_price_decay() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = scenario.ctx();

    let treasury = coin::create_treasury_cap_for_testing<dutch_auction::DUTCH_AUCTION>(ctx);
    dutch_auction::create_for_testing(
        treasury,
        START_PRICE,
        END_PRICE,
        DURATION_MS,
        TOTAL_SUPPLY,
        ctx,
    );

    scenario.next_tx(ADMIN);

    // Start auction with clock at t=0
    let mut auction = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let cap = test_scenario::take_from_sender<dutch_auction::AdminCap>(&mut scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk, 0);
    dutch_auction::start_auction(&cap, &mut auction, START_PRICE, END_PRICE, DURATION_MS, &clk);
    assert!(dutch_auction::state(&auction) == 1); // ACTIVE
    test_scenario::return_to_sender(&mut scenario, cap);
    clock::destroy_for_testing(clk);

    // At t=0: price = start_price = 10
    let mut clk0 = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk0, 0);
    let p0 = dutch_auction::current_price(&auction, &clk0);
    assert!(p0 == START_PRICE);
    clock::destroy_for_testing(clk0);
    test_scenario::return_shared(auction);

    // At t=900s: price = 10 - 8*900000/3600000 = 10 - 2 = 8
    scenario.next_tx(ADMIN);
    let mut auction1 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let mut clk15 = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk15, 900_000);
    let p15 = dutch_auction::current_price(&auction1, &clk15);
    assert!(p15 == 8);
    clock::destroy_for_testing(clk15);
    test_scenario::return_shared(auction1);

    // At t=1800s: price = 10 - 8*1800000/3600000 = 10 - 4 = 6
    scenario.next_tx(ADMIN);
    let mut auction2 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let mut clk30 = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk30, 1_800_000);
    let p30 = dutch_auction::current_price(&auction2, &clk30);
    assert!(p30 == 6);
    clock::destroy_for_testing(clk30);
    test_scenario::return_shared(auction2);

    // At t=3600s: price = end_price = 2
    scenario.next_tx(ADMIN);
    let mut auction3 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let mut clk60 = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk60, 3_600_000);
    let p60 = dutch_auction::current_price(&auction3, &clk60);
    assert!(p60 == END_PRICE);
    clock::destroy_for_testing(clk60);
    test_scenario::return_shared(auction3);

    scenario.end();
}

#[test]
fun test_buy_and_claim() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = scenario.ctx();

    let treasury = coin::create_treasury_cap_for_testing<dutch_auction::DUTCH_AUCTION>(ctx);
    dutch_auction::create_for_testing(
        treasury,
        START_PRICE,
        END_PRICE,
        DURATION_MS,
        TOTAL_SUPPLY,
        ctx,
    );

    // Start auction at t=0
    scenario.next_tx(ADMIN);
    let mut auction = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let cap = test_scenario::take_from_sender<dutch_auction::AdminCap>(&mut scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk, 0);
    dutch_auction::start_auction(&cap, &mut auction, START_PRICE, END_PRICE, DURATION_MS, &clk);
    test_scenario::return_to_sender(&mut scenario, cap);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(auction);

    // User1 buys at t=900s, price=8 MIST/base
    // Pays 8 SUI (8_000_000_000 MIST) → gets 8_000_000_000/8 = 1_000_000_000 base units (1 token)
    scenario.next_tx(USER1);
    let mut auction2 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let mut clk2 = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk2, 900_000);
    let payment1 = mint_sui(8_000_000_000, scenario.ctx());
    dutch_auction::buy(&mut auction2, payment1, &clk2, scenario.ctx());
    assert!(dutch_auction::remaining(&auction2) == TOTAL_SUPPLY - 1_000_000_000);
    assert!(dutch_auction::has_purchased(&auction2, USER1));
    clock::destroy_for_testing(clk2);
    test_scenario::return_shared(auction2);

    // Admin ends auction after duration
    scenario.next_tx(ADMIN);
    let mut auction3 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let cap2 = test_scenario::take_from_sender<dutch_auction::AdminCap>(&mut scenario);
    let mut clk3 = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk3, 4_000_000);
    dutch_auction::end_auction(&cap2, &mut auction3, &clk3);
    assert!(dutch_auction::state(&auction3) == 2); // SETTLED
    test_scenario::return_to_sender(&mut scenario, cap2);
    clock::destroy_for_testing(clk3);
    test_scenario::return_shared(auction3);

    // User1 claims tokens
    scenario.next_tx(USER1);
    let mut auction4 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let token = dutch_auction::claim(&mut auction4, scenario.ctx());
    assert!(coin::value(&token) == 1_000_000_000);
    sui::transfer::public_transfer(token, test_scenario::sender(&mut scenario));
    test_scenario::return_shared(auction4);

    scenario.end();
}

#[test]
fun test_multiple_buyers_different_prices() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = scenario.ctx();

    let treasury = coin::create_treasury_cap_for_testing<dutch_auction::DUTCH_AUCTION>(ctx);
    dutch_auction::create_for_testing(
        treasury,
        START_PRICE,
        END_PRICE,
        DURATION_MS,
        TOTAL_SUPPLY,
        ctx,
    );

    // Start auction
    scenario.next_tx(ADMIN);
    let mut auction = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let cap = test_scenario::take_from_sender<dutch_auction::AdminCap>(&mut scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk, 0);
    dutch_auction::start_auction(&cap, &mut auction, START_PRICE, END_PRICE, DURATION_MS, &clk);
    test_scenario::return_to_sender(&mut scenario, cap);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(auction);

    // User1 buys at t=0, price=10 → pays 10 SUI → gets 10_000_000_000/10 = 1_000_000_000 (1 token)
    scenario.next_tx(USER1);
    let mut auction1 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let mut clk1 = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk1, 0);
    let pay1 = mint_sui(10_000_000_000, scenario.ctx());
    dutch_auction::buy(&mut auction1, pay1, &clk1, scenario.ctx());
    clock::destroy_for_testing(clk1);
    test_scenario::return_shared(auction1);

    // User2 buys at t=1800s, price=6 → pays 6 SUI → gets 6_000_000_000/6 = 1_000_000_000 (1 token)
    scenario.next_tx(USER2);
    let mut auction2 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let mut clk2 = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk2, 1_800_000);
    let pay2 = mint_sui(6_000_000_000, scenario.ctx());
    dutch_auction::buy(&mut auction2, pay2, &clk2, scenario.ctx());
    clock::destroy_for_testing(clk2);
    test_scenario::return_shared(auction2);

    // End auction
    scenario.next_tx(ADMIN);
    let mut auction3 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let cap2 = test_scenario::take_from_sender<dutch_auction::AdminCap>(&mut scenario);
    let mut clk3 = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clk3, 4_000_000);
    dutch_auction::end_auction(&cap2, &mut auction3, &clk3);
    test_scenario::return_to_sender(&mut scenario, cap2);
    clock::destroy_for_testing(clk3);
    test_scenario::return_shared(auction3);

    // Both claim — same token count, different prices paid
    scenario.next_tx(USER1);
    let mut auction4 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let t1 = dutch_auction::claim(&mut auction4, scenario.ctx());
    assert!(coin::value(&t1) == 1_000_000_000);
    sui::transfer::public_transfer(t1, test_scenario::sender(&mut scenario));
    test_scenario::return_shared(auction4);

    scenario.next_tx(USER2);
    let mut auction5 = test_scenario::take_shared<dutch_auction::DutchAuctionRound>(&scenario);
    let t2 = dutch_auction::claim(&mut auction5, scenario.ctx());
    assert!(coin::value(&t2) == 1_000_000_000);
    sui::transfer::public_transfer(t2, test_scenario::sender(&mut scenario));
    test_scenario::return_shared(auction5);

    scenario.end();
}
