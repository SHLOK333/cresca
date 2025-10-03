/**
 * @title LeanIMTInclusionProof function (Noir equivalent)
 * @dev Function for verifying inclusion proofs in a Lean Incremental Merkle Tree using BLAKE3 hashes.
*/
pub fn lean_imt_inclusion_proof<let MAX_DEPTH: u32>(
    leaf: Field,
    leaf_index: Field, // The index of the leaf.
    siblings: [Field; MAX_DEPTH],
) -> Field {
    let path_bits_bool: [u1; MAX_DEPTH] = leaf_index.to_le_bits();

    // `nodes` array to store computed node values at each level
    // Size is MAX_DEPTH + 1 to store the initial leaf and results of MAX_DEPTH hashing/propagation steps.
    let mut nodes: [Field; MAX_DEPTH + 1] = [0 as Field; MAX_DEPTH + 1];

    // Initialize with the leaf value
    nodes[0] = leaf;

    // For each level up to MAX_DEPTH
    for i in 0..MAX_DEPTH {
        let current_node = nodes[i];
        let sibling_node = siblings[i];

        // `path_bits_field[i]` determines if `current_node` is a left (0) or right (1) child.
        let path_direction_bit = path_bits_bool[i]; // 0 if current_node is left, 1 if current_node is right

        // LeanIMT feature: if sibling_node is empty (0), propagate current_node.
        // Otherwise, use the hash.
        // `is_sibling_empty_selector` will be 1 if sibling_node is 0, and 0 otherwise.
        let is_sibling_empty_selector = if sibling_node == 0 {
            1 as Field
        } else {
            0 as Field
        };

        if is_sibling_empty_selector == 1 {
            nodes[i + 1] = current_node;
        } else {
            let mut left_input: Field = 0 as Field;
            let mut right_input: Field = 0 as Field;
            if path_direction_bit == 0 {
                left_input = current_node;
                right_input = sibling_node;
            } else {
                left_input = sibling_node;
                right_input = current_node;
            }

            // Hash the correctly ordered pair using BLAKE3
            let hashed_pair = poseidon::poseidon2::Poseidon2::hash([left_input, right_input], 2);
            nodes[i + 1] = hashed_pair;
        }
    }

    // Output the final computed root
    nodes[MAX_DEPTH]
}

#[test]
pub fn test_lean_imt_inclusion_proof() {
    let leaf: Field = (4 as u8).into();
    let leaf_index: Field = (3 as u8).into();
    let siblings: [Field; 8] = [
        3,
        0x038682aa1cb5ae4e0a3f13da432a95c77c5c111f6f030faf9cad641ce1ed7383,
        0x232400b3cca0da78d26295f345d21e9bf8949238bee02b285140ebf183119982,
        0,
        0,
        0,
        0,
        0,
    ];
    let root = lean_imt_inclusion_proof(leaf, leaf_index, siblings);
    assert(root == 0x05d7e5aaddb74c086c24617065e8c97dea94b86fdae0eab7b498249e0dfee2a8);
}
