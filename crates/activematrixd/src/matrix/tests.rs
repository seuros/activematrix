use super::*;

#[test]
fn path_segments_keep_matrix_sigils_intact() {
    const CASES: &[(&str, &str)] = &[
        ("!room:matrix.test", "%21room%3Amatrix.test"),
        ("$event+id/with=chars", "%24event%2Bid%2Fwith%3Dchars"),
        ("@bot:matrix.test", "%40bot%3Amatrix.test"),
        ("m.room.message", "m.room.message"),
        ("0199e1a2-0000-7000-8000-000000000000", "0199e1a2-0000-7000-8000-000000000000"),
    ];
    for (input, expected) in CASES {
        assert_eq!(seg(input), *expected, "input: {input:?}");
    }
}
