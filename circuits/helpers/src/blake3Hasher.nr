use std::{field::bytes32_to_field, hash::blake3};

pub fn black3_hash_to_field(inputs: [Field]) -> Field {
    let mut sum = 0;

    for input in inputs {
        let input_bytes: [u8; 32] = input.to_le_bytes();
        sum += bytes32_to_field(blake3(input_bytes));
    }

    sum
}
