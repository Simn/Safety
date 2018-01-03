#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import eval.vm.Context in EvalContext;
#end

class Validator {
#if macro
	static var expectedErrors:Array<{method:String, pos:Position}>;

	static public function register() {
		if(Context.defined('display')) return;
		Context.onAfterTyping(validate);
		expectedErrors = [];
	}

	static function validate(_) {
		var totalExpectedErrors = expectedErrors.length;
		var errors = Safety.plugin.getErrors();
		var i = 0;
		while(i < errors.length) {
			var error = errors[i];
			var wasExpected = false;
			for(expected in expectedErrors) {
				if(posContains(expected.pos, error.pos)) {
					expectedErrors.remove(expected);
					wasExpected = true;
					break;
				}
			}
			if(wasExpected) {
				errors.remove(error);
			} else {
				++i;
			}
		}

		for(error in errors) {
			Context.warning(error.msg, error.pos);
		}
		for(expected in expectedErrors) {
			Context.warning('Expression was expected to fail, but it did not fail in "${expected.method}".', expected.pos);
		}
		if(errors.length + expectedErrors.length > 0) {
			if(!Context.defined('VALIDATOR_DONT_FAIL')) {
				Context.error('Tests failed. See warnings.', Context.currentPos());
			}
		} else {
			Sys.println('Tests passed. $totalExpectedErrors expected errors spotted.');
		}
	}

	static function posContains(pos:Position, subPos:Position):Bool {
		var infos = Context.getPosInfos(pos);
		var subInfos = Context.getPosInfos(subPos);
		return infos.file == subInfos.file && infos.min <= subInfos.min && infos.max >= subInfos.max;
	}
#end

	macro static public function shouldFail(expr:Expr):Expr {
		expectedErrors.push({method:Context.getLocalMethod(), pos:expr.pos});
		return expr;
	}
}