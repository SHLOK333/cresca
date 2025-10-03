pub mod commitment;
pub mod LeanIMTInclusionProof;
pub mod blake3Hasher;

#[test]
pub fn test_commitment_hasher() {
    let commitment = commitment::commitment_hasher(1, 2, 3, 4);
    println(commitment);
}
