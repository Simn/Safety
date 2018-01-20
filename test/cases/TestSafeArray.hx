package cases;

import safety.OutOfBoundsException;

class TestSafeArray extends BaseCase {
	public function testRead_outOfBounds_shouldThrow() {
		var a:SafeArray<Int> = [];
		assert.raises(() -> a[0], OutOfBoundsException);
		assert.raises(() -> a[-1], OutOfBoundsException);
	}

	public function testWrite_outOfBounds_shouldThrow() {
		var a:SafeArray<Int> = [];
		assert.raises(() -> a[10] = 2, OutOfBoundsException);
		assert.raises(() -> a[-1] = 2, OutOfBoundsException);
	}

	public function testWrite_atLength_shouldPass() {
		var a:SafeArray<Int> = [];
		a[a.length] = 5;
		assert.same([5], a);
	}
}