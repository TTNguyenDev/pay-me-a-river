module overmind::pay_me_a_river {
    use aptos_std::table::Table;
    use aptos_std::table;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::Coin;
    use aptos_framework::coin;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use std::signer;
    use std::vector;

    const ESENDER_CAN_NOT_BE_RECEIVER: u64 = 1;
    const ENUMBER_INVALID: u64 = 2;
    const EPAYMENT_DOES_NOT_EXIST: u64 = 3;
    const ESTREAM_DOES_NOT_EXIST: u64 = 4;
    const ESTREAM_IS_ACTIVE: u64 = 5;
    const ESIGNER_ADDRESS_IS_NOT_SENDER_OR_RECEIVER: u64 = 6;

    struct Stream has store {
        sender: address,
        receiver: address,
        length_in_seconds: u64,
        start_time: u64,
        coins: Coin<AptosCoin>,
    }

    struct Payments has key {
        streams: Table<address, Stream>,
        signer_capability: account::SignerCapability,
    }

    public fun check_sender_is_not_receiver(sender: address, receiver: address) {
        assert!(sender != receiver, ESENDER_CAN_NOT_BE_RECEIVER)
    }

    public fun check_number_is_valid(number: u64) {
        assert!(number > 0, ENUMBER_INVALID)
    }

    public fun check_payment_exists(sender_address: address) {
        assert!(exists<Payments>(sender_address), EPAYMENT_DOES_NOT_EXIST);
    }

    public fun check_stream_exists(payments: &Payments, stream_address: address) {
        assert!(table::contains(&payments.streams, stream_address), ESTREAM_DOES_NOT_EXIST)
    }

    public fun check_stream_is_not_active(payments: &Payments, stream_address: address) {
        let number = table::borrow(&payments.streams, stream_address).start_time;
        assert!(number > 0, ESTREAM_IS_ACTIVE)
    }

    public fun check_signer_address_is_sender_or_receiver(
        signer_address: address,
        sender_address: address,
        receiver_address: address
    ) {
        assert!(signer_address == sender_address || signer_address == receiver_address, ESIGNER_ADDRESS_IS_NOT_SENDER_OR_RECEIVER)
    }

    public fun calculate_stream_claim_amount(total_amount: u64, start_time: u64, length_in_seconds: u64): u64 {
        if (total_amount == 0 || length_in_seconds == 0) {
            return 0
        };
        total_amount / length_in_seconds * (timestamp::now_seconds() - start_time)
    }

    public entry fun create_stream(
        signer: &signer,
        receiver_address: address,
        amount: u64,
        length_in_seconds: u64
    ) acquires Payments {
        let account_addr = signer::address_of(signer);
        check_sender_is_not_receiver(account_addr, receiver_address);
       
        if (!exists<Payments>(account_addr)) {
            let (resource_signer, resource_signer_cap) = aptos_framework::account::create_resource_account(signer, vector::empty<u8>());
            coin::register<AptosCoin>(&resource_signer);
            coin::transfer<AptosCoin>(signer, signer::address_of(&resource_signer), amount);
            let coins = coin::withdraw<AptosCoin>(&resource_signer, amount);
            let stream = Stream {
                sender: account_addr,
                receiver: receiver_address,
                length_in_seconds: length_in_seconds,
                start_time: 0,
                coins: coins
            };

            let streams = table::new<address, Stream>();
            table::add(&mut streams, receiver_address, stream);
            move_to(signer, Payments {
                streams: streams,
                signer_capability: resource_signer_cap
            });
        } else {
            let payments = borrow_global_mut<Payments>(account_addr);
            let resource_signer = account::create_signer_with_capability(&payments.signer_capability);
            coin::transfer<AptosCoin>(signer, signer::address_of(&resource_signer), amount);
            let coins = coin::withdraw<AptosCoin>(&resource_signer, amount);
            let stream = Stream {
                sender: account_addr,
                receiver: receiver_address,
                length_in_seconds: length_in_seconds,
                start_time: 0,
                coins: coins
            };
            table::add(&mut payments.streams, receiver_address, stream);
        }
    }

    public entry fun accept_stream(signer: &signer, sender_address: address) acquires Payments {
        let payments = borrow_global_mut<Payments>(sender_address);
        check_payment_exists(sender_address);
        let receiver_address = signer::address_of(signer);
        check_stream_exists(payments, receiver_address);
        check_stream_is_not_active(payments, receiver_address);
        let stream: &mut Stream = table::borrow_mut(&mut payments.streams, receiver_address);
        stream.start_time = timestamp::now_seconds();
    }

    public entry fun claim_stream(signer: &signer, sender_address: address) acquires Payments {
        let receiver_address = signer::address_of(signer);
        check_payment_exists(sender_address);
        let payments = borrow_global_mut<Payments>(sender_address);
        check_stream_exists(payments, receiver_address);
        let (period_in_seconds, start_time, value) = get_stream(sender_address, receiver_address);
        let amount = calculate_stream_claim_amount(value, start_time, period_in_seconds);
        
        let payments = borrow_global_mut<Payments>(sender_address);
        
        let length_in_seconds = table::borrow(&payments.streams, receiver_address).length_in_seconds;
        let start_time = table::borrow(&payments.streams, receiver_address).start_time;
        
        let stream = table::borrow_mut(&mut payments.streams, receiver_address);
        if (length_in_seconds > (timestamp::now_seconds() - start_time)) {
            stream.length_in_seconds = length_in_seconds - timestamp::now_seconds() + start_time;
            stream.start_time = timestamp::now_seconds();
            let coins = coin::extract(&mut stream.coins, amount);
            coin::deposit<AptosCoin>(receiver_address, coins);  
        } else {
            stream.length_in_seconds = 0;
            stream.start_time = 0;
            let coins = coin::extract_all(&mut stream.coins);
            coin::deposit<AptosCoin>(receiver_address, coins);
        };
    }

    public entry fun cancel_stream(
        signer: &signer,
        sender_address: address,
        receiver_address: address
    ) acquires Payments {
        let signer_address = signer::address_of(signer);
        check_signer_address_is_sender_or_receiver(signer_address, sender_address, receiver_address);
        check_payment_exists(sender_address);
        let payments = borrow_global_mut<Payments>(sender_address);
        check_stream_exists(payments, receiver_address);

        let Stream {sender: _, receiver: _, length_in_seconds, start_time, coins } = table::remove(&mut payments.streams, receiver_address);
        check_number_is_valid(coin::value(&coins));
       
        //Not active stream
        if (start_time == 0) {
            let coins = coin::extract_all(&mut coins);
            coin::deposit<AptosCoin>(sender_address, coins);
        } else {
            let amount = calculate_stream_claim_amount(coin::value(&coins), start_time, length_in_seconds);
            let receiver_coin = coin::extract(&mut coins, amount);
            coin::deposit<AptosCoin>(receiver_address, receiver_coin);
            let coins = coin::extract_all(&mut coins);
            coin::deposit<AptosCoin>(sender_address, coins);
        };
        coin::destroy_zero<AptosCoin>(coins);
    }

    #[view]
    public fun get_stream(sender_address: address, receiver_address: address): (u64, u64, u64) acquires Payments {
        let payments = borrow_global_mut<Payments>(sender_address);
        let stream = table::borrow(&payments.streams, receiver_address);
        (stream.length_in_seconds, stream.start_time, coin::value(&stream.coins))
    }
}
