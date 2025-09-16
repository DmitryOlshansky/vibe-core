/**
	Multi-threaded task pool implementation.

	Copyright: © 2012-2020 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.taskpool;

import std.traits;
import std.typecons;
import vibe.core.concurrency;
import vibe.internal.traits;
import vibe.core.task;
import vibe.core.core;

import photon;

/** Implements a shared, multi-threaded task pool.
*/
shared final class TaskPool {
	size_t m_threadCount;
	/** Creates a new task pool with the specified number of threads.

		Params:
			thread_count = The number of worker threads to create
			thread_name_prefix = Optional prefix to use for thread names
	*/
	this(size_t thread_count = logicalProcessorCount(), string thread_name_prefix = "vibe")
	@safe nothrow {
		m_threadCount = thread_count;
	}

	/** Returns the number of worker threads.
	*/
	@property size_t threadCount() const shared nothrow { return m_threadCount; }

	/** Instructs all worker threads to terminate and waits until all have
		finished.
	*/
	void terminate()
	@safe nothrow {
	}

	/** Runs a new asynchronous task in a worker thread.

		Only function pointers with weakly isolated arguments are allowed to be
		able to guarantee thread-safety.
	*/
	void runTask(FT, ARGS...)(FT func, auto ref ARGS args)
		if (isFunctionPointer!FT)
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		vibe.core.core.runTask(func, args);
	}
	/// ditto
	void runTask(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
		if (is(typeof(__traits(getMember, object, __traits(identifier, method)))))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		auto func = &__traits(getMember, object, __traits(identifier, method));
		vibe.core.core.runTask(func, args);
	}
	/// ditto
	void runTask(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
		if (isFunctionPointer!FT)
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		vibe.core.core.runTask(func, args);
	}
	/// ditto
	void runTask(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
		if (is(typeof(__traits(getMember, object, __traits(identifier, method)))))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		auto func = &__traits(getMember, object, __traits(identifier, method));
		vibe.core.core.runTask(func, args);
	}

	/** Runs a new asynchronous task in a worker thread, returning the task handle.

		This function will yield and wait for the new task to be created and started
		in the worker thread, then resume and return it.

		Only function pointers with weakly isolated arguments are allowed to be
		able to guarantee thread-safety.
	*/
	Task runTaskH(FT, ARGS...)(FT func, auto ref ARGS args)
		if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		return doRunTaskH(TaskSettings.init, func, args);
	}
	/// ditto
	Task runTaskH(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
		if (isNothrowMethod!(shared(T), method, ARGS))
	{
		static void wrapper()(shared(T) object, ref ARGS args) {
			__traits(getMember, object, __traits(identifier, method))(args);
		}
		return runTaskH(&wrapper!(), object, args);
	}
	/// ditto
	Task runTaskH(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
		if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		return doRunTaskH(settings, func, args);
	}
	/// ditto
	Task runTaskH(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
		if (isNothrowMethod!(shared(T), method, ARGS))
	{
		static void wrapper()(shared(T) object, ref ARGS args) {
			__traits(getMember, object, __traits(identifier, method))(args);
		}
		return runTaskH(settings, &wrapper!(), object, args);
	}

	// NOTE: needs to be a separate function to avoid recursion for the
	//       workaround above, which breaks @safe inference
	private Task doRunTaskH(FT, ARGS...)(TaskSettings settings, FT func, ref ARGS args)
		if (isFunctionPointer!FT)
	{
		import std.typecons : Typedef;
		import vibe.core.task : needsMove;

		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		auto ch = channel!Task(1);

		static string argdefs()
		{
			string ret;
			foreach (i, A; ARGS) {
				if (i > 0) ret ~= ", ";
				if (!needsMove!A) ret ~= "ref ";
				ret ~= "ARGS["~i.stringof~"] arg_"~i.stringof;
			}
			return ret;
		}

		static string argvals()
		{
			string ret;
			foreach (i, A; ARGS) {
				if (i > 0) ret ~= ", ";
				ret ~= "arg_"~i.stringof;
				if (needsMove!A) ret ~= ".move";
			}
			return ret;
		}

		mixin("static void taskFun(Channel!Task ch, FT func, " ~ argdefs() ~ ") {"
			~ "	try ch.put(Task.getThis());"
			~ "	catch (Exception e) assert(false, e.msg);"
			~ "	ch = Channel!Task.init;"
			~ "	func("~argvals()~");"
			~ "}");
		runTask(&taskFun, ch, func, args);

		Task ret;
		if (ch.empty())
			assert(false, "Channel closed without passing a task handle!?");
		ret = ch.front();
		ch.popFront();
		ch.close();
		return ret;
	}


	/** Runs a new asynchronous task in all worker threads concurrently.

		This function is mainly useful for long-living tasks that distribute their
		work across all CPU cores. Only function pointers with weakly isolated
		arguments are allowed to be able to guarantee thread-safety.

		The number of tasks started is guaranteed to be equal to
		`threadCount`.
	*/
	void runTaskDist(FT, ARGS...)(FT func, auto ref ARGS args)
		if (isFunctionPointer!FT/* && isNothrowCallable!(FT, ARGS)*/)
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		runTaskDist_unsafe(TaskSettings.init, func, args);
	}
	/// ditto
	void runTaskDist(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
		if (isNothrowMethod!(shared(T), method, ARGS))
	{
		auto func = &__traits(getMember, object, __traits(identifier, method));
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		runTaskDist_unsafe(TaskSettings.init, func, args);
	}
	/// ditto
	void runTaskDist(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
		if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		runTaskDist_unsafe(settings, func, args);
	}
	/// ditto
	void runTaskDist(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
		if (isNothrowMethod!(shared(T), method, ARGS))
	{
		auto func = &__traits(getMember, object, __traits(identifier, method));
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		runTaskDist_unsafe(settings, func, args);
	}

	private void runTaskDist_unsafe(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args) {
		foreach (_; 0..this.threadCount) {
			runTask(func, args);
		}
	}

	/** Runs a new asynchronous task in all worker threads and returns the handles.

		`on_handle` is an alias to a callble that takes a `Task` as its only
		argument and is called for every task instance that gets created.

		See_also: `runTaskDist`
	*/
	void runTaskDistH(HCB, FT, ARGS...)(scope HCB on_handle, FT func, auto ref ARGS args)
		if (!is(HCB == TaskSettings))
	{
		runTaskDistH(TaskSettings.init, on_handle, func, args);
	}
	/// ditto
	void runTaskDistH(HCB, FT, ARGS...)(TaskSettings settings, scope HCB on_handle, FT func, auto ref ARGS args)
	{

		// TODO: support non-copyable argument types using .move
		auto ch = channel!Task(this.threadCount);

		static void call(Channel!Task ch, FT func, ARGS args) {
			try ch.put(Task.getThis());
			catch (Exception e) assert(false, e.msg);
			func(args);
		}
		runTaskDist(settings, &call, ch, func, args);

		foreach (i; 0 .. this.threadCount) {
			if (ch.empty)
				assert(false, "Worker thread failed to report task handle");
			on_handle(ch.front);
			ch.popFront();
		}

		ch.close();
	}
}

unittest { // #138 - immutable arguments
	initPhoton();
	auto tp = new shared TaskPool;
	struct S { int[] x; }
	auto s = immutable(S)([1, 2]);
	go({
		tp.runTaskH((immutable S s) { assert(s.x == [1, 2]); }, s)
		.joinUninterruptible();
	});
	tp.terminate();
	runScheduler();
}
