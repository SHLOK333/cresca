use poseidon;

/**
 * @title CommitmentHasher function
 * @dev Function for computing commitment hashes, precommitments and nullifier hashes
 */
pub fn commitment_hasher(
    nullifier: Field, // Nullifier of commitment
    value: Field, // Value of commitment
    label: Field,
    secret: Field, // Secret of commitment
) -> (Field) {
    // println(nullifier);

    let precommitment = poseidon::poseidon2::Poseidon2::hash([nullifier, secret], 2);
    let commitment = poseidon::poseidon2::Poseidon2::hash([value, label, precommitment], 3);

    // println([precommitment, commitment]);
    (commitment)
}

#[test]
pub fn test_commitment_hasher() {
    let nullifier: Field = (1 as u8).into();
    let secret: Field = (2 as u8).into();
    let value: Field = (1000000000000000000 as u64).into();
    let label: Field = (0x4838b106fce9647bdf1e7877bf73ce8b0bad5f97).into();
    let _commitment = commitment_hasher(nullifier, value, label, secret);
    assert_eq(_commitment, 0x16e83a643e94248403eb0078a4b6996acf63857e47be823fdba2f0274aa66447)
}
