/**
	This module contains the core functionality of the vibe.d framework.

	Copyright: © 2012-2020 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.core;

public import vibe.core.task;

import vibe.core.args;
import vibe.core.concurrency;
import vibe.core.log;
import vibe.core.sync : ManualEvent, createSharedManualEvent;
import vibe.core.taskpool;

import std.algorithm;
import std.conv;
import std.encoding;
import core.exception;
import std.exception;
import std.functional;
import std.range : empty, front, popFront;
import std.string;
import std.traits : isFunctionPointer;
import std.typecons : Flag, Yes, Typedef, Tuple, tuple;
import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.stdc.stdlib;
import core.thread;

import photon;

enum ExitReason {
	exited,
	idle
}

version(Posix)
{
	import core.sys.posix.signal;
	import core.sys.posix.unistd;
	import core.sys.posix.pwd;

	static if (__traits(compiles, {import core.sys.posix.grp; getgrgid(0);})) {
		import core.sys.posix.grp;
	} else {
		extern (C) {
			struct group {
				char*   gr_name;
				char*   gr_passwd;
				gid_t   gr_gid;
				char**  gr_mem;
			}
			group* getgrgid(gid_t);
			group* getgrnam(in char*);
		}
	}
}

version (Windows)
{
	import core.stdc.signal;
}


/**************************************************************************************************/
/* Public functions                                                                               */
/**************************************************************************************************/

/**
	Performs final initialization and runs the event loop.

	This function performs three tasks:
	$(OL
		$(LI Makes sure that no unrecognized command line options are passed to
			the application and potentially displays command line help. See also
			`vibe.core.args.finalizeCommandLineOptions`.)
		$(LI Performs privilege lowering if required.)
		$(LI Runs the event loop and blocks until it finishes.)
	)

	Params:
		args_out = Optional parameter to receive unrecognized command line
			arguments. If left to `null`, an error will be reported if
			any unrecognized argument is passed.

	See_also: ` vibe.core.args.finalizeCommandLineOptions`, `lowerPrivileges`,
		`runEventLoop`
*/
int runApplication(string[]* args_out = null)
@safe {
	try if (!() @trusted { return finalizeCommandLineOptions(args_out); } () ) return 0;
	catch (Exception e) {
		logDiagnostic("Error processing command line: %s", e.msg);
		return 1;
	}

	lowerPrivileges();

	logDiagnostic("Running event loop...");
	int status;
	version (VibeDebugCatchAll) {
		try {
			status = runEventLoop();
		} catch (Throwable th) {
			th.logException("Unhandled exception in event loop");
			return 1;
		}
	} else {
		status = runEventLoop();
	}

	logDiagnostic("Event loop exited with status %d.", status);
	return status;
}

/// A simple echo server, listening on a privileged TCP port.
unittest {
	import vibe.core.core;
	import vibe.core.net;

	int main()
	{
		// first, perform any application specific setup (privileged ports still
		// available if run as root)
		listenTCP(7, (conn) {
			try conn.write(conn);
			catch (Exception e) { /* log error */ }
		});

		// then use runApplication to perform the remaining initialization and
		// to run the event loop
		return runApplication();
	}
}

/** The same as above, but performing the initialization sequence manually.

	This allows to skip any additional initialization (opening the listening
	port) if an invalid command line argument or the `--help`  switch is
	passed to the application.
*/
unittest {
	import vibe.core.core;
	import vibe.core.net;

	int main()
	{
		// process the command line first, to be able to skip the application
		// setup if not required
		if (!finalizeCommandLineOptions()) return 0;

		// then set up the application
		listenTCP(7, (conn) {
			try conn.write(conn);
			catch (Exception e) { /* log error */ }
		});

		// finally, perform privilege lowering (safe to skip for non-server
		// applications)
		lowerPrivileges();

		// and start the event loop
		return runEventLoop();
	}
}


/**
	Starts the vibe.d event loop for the calling thread.

	Note that this function is usually called automatically by the vibe.d
	framework. However, if you provide your own `main()` function, you may need
	to call either this or `runApplication` manually.

	The event loop will by default continue running during the whole life time
	of the application, but calling `runEventLoop` multiple times in sequence
	is allowed. Tasks will be started and handled only while the event loop is
	running.

	Returns:
		The returned value is the suggested code to return to the operating
		system from the `main` function.

	See_Also: `runApplication`
*/
int runEventLoop()
@safe {
	runScheduler();
	return 0;
}

/**
	Stops the currently running event loop.

	Calling this function will cause the event loop to stop event processing and
	the corresponding call to runEventLoop() will return to its caller.

	Params:
		shutdown_all_threads = If true, exits event loops of all threads -
			false by default. Note that the event loops of all threads are
			automatically stopped when the main thread exits, so usually
			there is no need to set shutdown_all_threads to true.
*/
void exitEventLoop(bool shutdown_all_threads = false)
@safe nothrow {
	// noop
}

/**
	Process all pending events without blocking.

	Checks if events are ready to trigger immediately, and run their callbacks if so.

	Returns: Returns false $(I iff) exitEventLoop was called in the process.
*/
bool processEvents()
@safe nothrow {
	return true;
}

/**
	Wait once for events and process them.

	Params:
		timeout = Maximum amount of time to wait for an event. A duration of
			zero will cause the function to only process pending events. A
			duration of `Duration.max`, if necessary, will wait indefinitely
			until an event arrives.

*/
ExitReason runEventLoopOnce(Duration timeout=Duration.max)
@safe nothrow {
	return ExitReason.idle;
}

/**
	Sets a callback that is called whenever no events are left in the event queue.

	The callback delegate is called whenever all events in the event queue have been
	processed. Returning true from the callback will cause another idle event to
	be triggered immediately after processing any events that have arrived in the
	meantime. Returning false will instead wait until another event has arrived first.
*/
void setIdleHandler(void delegate() @safe nothrow del)
@safe nothrow {
	//noop
}
/// ditto
void setIdleHandler(bool delegate() @safe nothrow del)
@safe nothrow {
	//noop
}

/**
	Runs a new asynchronous task.

	task will be called synchronously from within the vibeRunTask call. It will
	continue to run until vibeYield() or any of the I/O or wait functions is
	called.

	Note that the maximum size of all args must not exceed `maxTaskParameterSize`.
*/
Task runTask(ARGS...)(void delegate(ARGS) @safe nothrow task, auto ref ARGS args)
{
	return runTask_Internal(task, args);
}
///
Task runTask(ARGS...)(void delegate(ARGS) @system nothrow task, auto ref ARGS args)
@system {
	return runTask_Internal(task, args);
}
/// ditto
Task runTask(CALLABLE, ARGS...)(CALLABLE task, auto ref ARGS args)
	if (!is(CALLABLE : void delegate(ARGS)) && isNothrowCallable!(CALLABLE, ARGS))
{
	return runTask_Internal(task, args);
}
/// ditto
Task runTask(ARGS...)(TaskSettings settings, void delegate(ARGS) @safe nothrow task, auto ref ARGS args)
{
	return runTask_Internal(task, args);
}
/// ditto
Task runTask(ARGS...)(TaskSettings settings, void delegate(ARGS) @system nothrow task, auto ref ARGS args)
@system {
	return runTask_Internal(task, args);
}
/// ditto
Task runTask(CALLABLE, ARGS...)(TaskSettings settings, CALLABLE task, auto ref ARGS args)
	if (!is(CALLABLE : void delegate(ARGS)) && isNothrowCallable!(CALLABLE, ARGS))
{
	return runTask_Internal(task, args);
}

package Task runTask_Internal(CALLABLE, ARGS...)(CALLABLE task, auto ref ARGS args) @trusted {
	import std.traits;
	import core.stdc.stdlib, core.stdc.string;
	alias Params = ParameterTypeTuple!CALLABLE;
	struct Tup(T...) {
		T args;
	}
	static if (Params.length == 0) {
		return go(() => task());
	}
	else {
		Tup!Params* tup = cast(Tup!Params*)malloc(Tup!Params.sizeof);
		Tup!Params init;
		memcpy(tup, &init, init.sizeof);
		foreach (i, ref el; args) {
			static if (needsMove!(typeof(el)))
				tup.args[i] = move(el);
			else
				*cast(Unqual!(typeof(el))*)&tup.args[i] = *cast(Unqual!(typeof(el))*)&el;
		}
		string code() {
			string buf = "task(";
			static foreach (i; 0..ARGS.length) {
				if (i != 0)
					buf ~= ",";
				static if (!isCopyable!(ARGS[i])) {
					buf ~= format("move(tup.args[%d])", i);
				} else {
					buf ~= format("tup.args[%d]", i);
				}
			}
			buf ~= ");";
			return buf;
		}
		return go(() {
			try {
				mixin(code());
			} finally {
				foreach (ref el; tup.args) {
					static if (hasElaborateDestructor!(typeof(el))) {
						destroy(el);
					}
				}
				free(tup);
			}
		});
	}
}

/+
unittest { // test proportional priority scheduling
	auto tm = setTimer(1000.msecs, { assert(false, "Test timeout"); });
	scope (exit) tm.stop();

	size_t a, b;
	auto t1 = runTask(TaskSettings(1), { while (a + b < 100) { a++; try yield(); catch (Exception e) assert(false); } });
	auto t2 = runTask(TaskSettings(10), { while (a + b < 100) { b++; try yield(); catch (Exception e) assert(false); } });
	runTask({
		t1.joinUninterruptible();
		t2.joinUninterruptible();
		exitEventLoop();
	});
	runEventLoop();
	assert(a + b == 100);
	assert(b.among(90, 91, 92)); // expect 1:10 ratio +-1
}
+/

/**
	Runs an asyncronous task that is guaranteed to finish before the caller's
	scope is left.
*/
void runTaskScoped(FT, ARGS)(scope FT callable, ARGS args)
{
	auto ev = event(false);
	go({
		callable(args);
		ev.trigger();
	});
	ev.wait();
	ev.dispose(); 
}

unittest { // ensure task.running is true directly after runTask
	runPhoton({
		Task t;
		bool hit = false;
		{
			auto l = yieldLock();
			t = runTask({ hit = true; });
			assert(!hit);
			assert(t.running);
		}
		t.join();
		assert(!t.running);
		assert(hit);
	});
}

unittest {
	initPhoton();
	import core.atomic : atomicOp;

	static struct S {
		shared(int)* rc;
		this(this) @safe nothrow { if (rc) atomicOp!"+="(*rc, 1); }
		~this() @safe nothrow { if (rc) atomicOp!"-="(*rc, 1); }
	}

	runTask({
		S s;
		s.rc = new int;
		*s.rc = 1;

		runTask((ref S sc) {
			auto rc = sc.rc;
			assert(*rc == 2);
			sc = S.init;
			assert(*rc == 1);
		}, s).joinUninterruptible();

		assert(*s.rc == 1);

		runWorkerTaskH((ref S sc) {
			auto rc = sc.rc;
			assert(*rc == 2);
			sc = S.init;
			assert(*rc == 1);
		}, s).joinUninterruptible();
		assert(*s.rc == 1);
	});
	runScheduler();
}


/**
	Runs a new asynchronous task in a worker thread.

	Only function pointers with weakly isolated arguments are allowed to be
	able to guarantee thread-safety.
*/
void runWorkerTask(FT, ARGS...)(FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	runTask_Internal(func, args);
}
/// ditto
void runWorkerTask(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	auto func = &__traits(getMember, object, __traits(identifier, method));
	runTask_Internal(func, args);
}
/// ditto
void runWorkerTask(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	runTask_Internal(func, args);
}
/// ditto
void runWorkerTask(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	auto func = &__traits(getMember, object, __traits(identifier, method));
	runTask_Internal(func, args);
}


/**
	Runs a new asynchronous task in a worker thread, returning the task handle.

	This function will yield and wait for the new task to be created and started
	in the worker thread, then resume and return it.

	Only function pointers with weakly isolated arguments are allowed to be
	able to guarantee thread-safety.
*/
Task runWorkerTaskH(FT, ARGS...)(FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	return runTask_Internal(func, args);
}
/// ditto
Task runWorkerTaskH(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	auto func = &__traits(getMember, object, __traits(identifier, method));
	return runTask_Internal(func, args);
}
/// ditto
Task runWorkerTaskH(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	return runTask_Internal(func, args);
}
/// ditto
Task runWorkerTaskH(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	return runTask_Internal(func, args);
}

/** Runs a new asynchronous task in all worker threads concurrently.

	This function is mainly useful for long-living tasks that distribute their
	work across all CPU cores. Only function pointers with weakly isolated
	arguments are allowed to be able to guarantee thread-safety.

	The number of tasks started is guaranteed to be equal to
	`threadCount`.
*/
void runWorkerTaskDist(FT, ARGS...)(FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	workerTaskPool.runTaskDist(func, args);
}
/// ditto
void runWorkerTaskDist(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	workerTaskPool.runTaskDist!method(object, args);
}
/// ditto
void runWorkerTaskDist(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	workerTaskPool.runTaskDist(func, args);
}
/// ditto
void runWorkerTaskDist(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	workerTaskPool.runTaskDist!method(object, args);
}

/// Running a worker task using a function
unittest {
	static void workerFunc(int param)
	{
		logInfo("Param: %s", param);
	}

	static void test()
	{
		runWorkerTask(&workerFunc, 42);
		runWorkerTask(&workerFunc, cast(ubyte)42); // implicit conversion #719
		runWorkerTaskDist(&workerFunc, 42);
		runWorkerTaskDist(&workerFunc, cast(ubyte)42); // implicit conversion #719
	}
}

/// Running a worker task using a class method
unittest {
	static class Test {
		void workerMethod(int param)
		shared nothrow {
			logInfo("Param: %s", param);
		}
	}

	static void test()
	{
		auto cls = new shared Test;
		runWorkerTask!(Test.workerMethod)(cls, 42);
		runWorkerTask!(Test.workerMethod)(cls, cast(ubyte)42); // #719
		//runWorkerTaskDist!(Test.workerMethod)(cls, 42);
		//runWorkerTaskDist!(Test.workerMethod)(cls, cast(ubyte)42); // #719
	}
}

/// Running a worker task using a function and communicating with it
unittest {
	
	static void workerFunc(Task caller)
	nothrow {
		int counter = 10;
		try {
			while (receiveOnly!string() == "ping" && --counter) {
				logInfo("pong");
				caller.send("pong");
			}
			caller.send("goodbye");
		} catch (Exception e) assert(false, e.msg);
	}

	static void test()
	{
		Task callee = runWorkerTaskH(&workerFunc, Task.getThis);
		do {
			logInfo("ping");
			callee.send("ping");
		} while (receiveOnly!string() == "pong");
	}

	static void work719(int) nothrow {}
	static void test719() { runWorkerTaskH(&work719, cast(ubyte)42); }
	
}

/// Running a worker task using a class method and communicating with it
unittest {
	
	static class Test {
		void workerMethod(Task caller)
		shared nothrow {
			int counter = 10;
			try {
				while (receiveOnly!string() == "ping" && --counter) {
					logInfo("pong");
					caller.send("pong");
				}
				caller.send("goodbye");
			} catch (Exception e) assert(false, e.msg);
		}
	}

	static void test()
	{
		auto cls = new shared Test;
		Task callee = runWorkerTaskH!(Test.workerMethod)(cls, Task.getThis());
		do {
			logInfo("ping");
			callee.send("ping");
		} while (receiveOnly!string() == "pong");
	}

	static class Class719 {
		void work(int) shared nothrow {}
	}
	static void test719() {
		auto cls = new shared Class719;
		runWorkerTaskH!(Class719.work)(cls, cast(ubyte)42);
	}
	
}

unittest { // run and join local task from outside of a task
	runPhoton({
		int i = 0;
		auto t = runTask({
			try sleep(1.msecs);
			catch (Exception e) assert(false, e.msg);
			i = 1;
		});
		t.join();
		assert(i == 1);
	});
}

unittest { // run and join worker task from outside of a task
	runPhoton({
		__gshared int i = 0;
		auto t = runWorkerTaskH({
			try sleep(5.msecs);
			catch (Exception e) assert(false, e.msg);
			i = 1;
		});
		t.join();
		assert(i == 1);
	});
}

/+
/**
	Runs a new asynchronous task in all worker threads concurrently.

	This function is mainly useful for long-living tasks that distribute their
	work across all CPU cores. Only function pointers with weakly isolated
	arguments are allowed to be able to guarantee thread-safety.

	The number of tasks started is guaranteed to be equal to
	`workerThreadCount`.
*/
void runWorkerTaskDist(FT, ARGS...)(FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskDist(func, args);
}
/// ditto
void runWorkerTaskDist(alias method, T, ARGS...)(shared(T) object, ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskDist!method(object, args);
}
/// ditto
void runWorkerTaskDist(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskDist(settings, func, args);
}
/// ditto
void runWorkerTaskDist(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskDist!method(settings, object, args);
}


/** Runs a new asynchronous task in all worker threads and returns the handles.

	`on_handle` is a callble that takes a `Task` as its only argument and is
	called for every task instance that gets created.

	See_also: `runWorkerTaskDist`
*/
void runWorkerTaskDistH(HCB, FT, ARGS...)(scope HCB on_handle, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	st_workerPool.runTaskDistH(on_handle, func, args);
}
/// ditto
void runWorkerTaskDistH(HCB, FT, ARGS...)(TaskSettings settings, scope HCB on_handle, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	st_workerPool.runTaskDistH(settings, on_handle, func, args);
}
+/

/** Groups together a set of tasks and ensures that no task outlives the group.

	This struct uses RAII to ensure that none of the associated tasks can
	outlive the group.
*/
struct TaskGroup {
	private {
		Task[] m_tasks;
	}

	@disable this(this);

	~this()
	@safe nothrow {
		joinUninterruptible();
	}

	/// Runs a new task and adds it to the group.
	Task run(ARGS...)(ARGS args)
	{
		auto t = runTask(args);
		add(t);
		return t;
	}

	/// Runs a new task and adds it to the group.
	Task runInWorker(ARGS...)(ARGS args)
	{
		auto t = runWorkerTaskH(args);
		add(t);
		return t;
	}

	/// Adds an existing task to the group.
	void add(Task t)
	@safe nothrow {
		if (t.running)
			m_tasks ~= t;
		cleanup();
	}

	/// Interrupts all tasks of the group.
	void interrupt()
	@safe nothrow {
		foreach (t; m_tasks)
			t.interrupt();
	}

	/// Joins all tasks in the group.
	void join()
	@safe {
		foreach (t; m_tasks)
			t.join();
		cleanup();
	}
	/// ditto
	void joinUninterruptible()
	@safe nothrow {
		foreach (t; m_tasks)
			t.joinUninterruptible();
		cleanup();
	}

	private void cleanup()
	@safe nothrow {
		size_t j = 0;
		foreach (i; 0 .. m_tasks.length)
			if (m_tasks[i].running) {
				if (i != j) m_tasks[j] = m_tasks[i];
				j++;
			}
		m_tasks.length = j;
		() @trusted { m_tasks.assumeSafeAppend(); } ();
	}
}


enum isCallable(CALLABLE, ARGS...) = is(typeof({ mixin(testCall!ARGS("CALLABLE.init")); }));
enum isNothrowCallable(CALLABLE, ARGS...) = is(typeof(() nothrow { mixin(testCall!ARGS("CALLABLE.init")); }));
enum isMethod(T, alias method, ARGS...) = is(typeof({ mixin(testCall!ARGS("__traits(getMember, T.init, __traits(identifier, method))")); }));
enum isNothrowMethod(T, alias method, ARGS...) = is(typeof(() nothrow { mixin(testCall!ARGS("__traits(getMember, T.init, __traits(identifier, method))")); }));
private string testCall(ARGS...)(string callable) {
	auto ret = callable ~ "(";
	foreach (i, Ti; ARGS) {
		if (i > 0) ret ~= ", ";
		static if (is(typeof((Ti a) => a)))
			ret ~= "(function ref ARGS["~i.stringof~"]() { static ARGS["~i.stringof~"] ret; return ret; }) ()";
		else
			ret ~= "ARGS["~i.stringof~"].init";
	}
	return ret ~ ");";
}

unittest {
	static assert(isCallable!(void function() @system));
	static assert(isCallable!(void function(int) @system, int));
	static assert(isCallable!(void function(ref int) @system, int));
	static assert(isNothrowCallable!(void function() nothrow @system));
	static assert(!isNothrowCallable!(void function() @system));

	struct S { @disable this(this); }
	static assert(isCallable!(void function(S) @system, S));
	static assert(isNothrowCallable!(void function(S) @system nothrow, S));
}


/**
	Sets up num worker threads.

	This function gives explicit control over the number of worker threads.
	Note, to have an effect the function must be called prior to related worker
	tasks functions which set up the default number of worker threads
	implicitly.

	Params:
		num = The number of worker threads to initialize. Defaults to
			`logicalProcessorCount`.
	See_also: `runWorkerTask`, `runWorkerTaskH`, `runWorkerTaskDist`
*/
public void setupWorkerThreads(uint num = 0)
@safe nothrow {
	// noop
}

/+
/** Returns the default worker task pool.

	This pool is used by `runWorkerTask`, `runWorkerTaskH` and
	`runWorkerTaskDist`.
*/
@property shared(TaskPool) workerTaskPool()
@safe nothrow {
	return st_workerPool;
}


package @property shared(TaskPool) ioWorkerTaskPool()
@safe nothrow {
	return st_ioWorkerPool;
}
+/

/** Determines the number of logical processors in the system.

	This number includes virtual cores on hyper-threading enabled CPUs.
*/
@property uint logicalProcessorCount()
@safe nothrow {
	import std.parallelism : totalCPUs;
	return totalCPUs;
}


/** Suspends the execution of the calling task to let other tasks and events be
	handled.

	Calling this function in short intervals is recommended if long CPU
	computations are carried out by a task. It can also be used in conjunction
	with Signals to implement cross-fiber events with no polling.

	Throws:
		May throw an `InterruptException` if `Task.interrupt()` gets called on
		the calling task.

	See_also: `yieldUninterruptible`
*/
void yield()
@safe {
	//TODO: yield in photon
	delay(1.usecs);
}

unittest {
	runPhoton({
		size_t ti;
		auto t = goOnSameThread({
			for (ti = 0; ti < 10; ti++)
				try yield();
				catch (Exception e) assert(false, e.msg);
		});

		foreach (i; 0 .. 5) yield();
		assert(ti > 0 && ti < 10, "Task did not interleave with yield loop outside of task");

		t.join();
		assert(ti == 10);
	});
}


/** Suspends the execution of the calling task to let other tasks and events be
	handled.

	This version of `yield` will not react to calls to `Task.interrupt` and will
	not throw any exceptions.

	See_also: `yield`
*/
void yieldUninterruptible()
@safe nothrow {
	// TODO: yield in photon
	delay(1.usecs);
}


/**
	Suspends the execution of the calling task until `switchToTask` is called
	manually.

	This low-level scheduling function is usually only used internally. Failure
	to call `switchToTask` will result in task starvation and resource leakage.

	Params:
		on_interrupt = If specified, is required to

	See_Also: `switchToTask`
*/
void hibernate(scope void delegate() @safe nothrow on_interrupt = null)
@safe nothrow {
	// noop
}


/**
	Switches execution to the given task.

	This function can be used in conjunction with `hibernate` to wake up a
	task. The task must live in the same thread as the caller.

	If no priority is specified, `TaskSwitchPriority.prioritized` or
	`TaskSwitchPriority.immediate` will be used, depending on whether a
	yield lock is currently active.

	Note that it is illegal to use `TaskSwitchPriority.immediate` if a yield
	lock is active.

	This function must only be called on tasks that belong to the calling
	thread and have previously been hibernated!

	See_Also: `hibernate`, `yieldLock`
*/
void switchToTask(Task t)
@safe nothrow {
	//noop
}
/// ditto
void switchToTask(Task t, TaskSwitchPriority priority)
@safe nothrow {
	// noop
}


/**
	Suspends the execution of the calling task for the specified amount of time.

	Note that other tasks of the same thread will continue to run during the
	wait time, in contrast to $(D core.thread.Thread.sleep), which shouldn't be
	used in vibe.d applications.

	Repeated_sleep:
	  As this method creates a new `Timer` every time, it is not recommended to
	  use it in a tight loop. For functions that calls `sleep` frequently,
	  it is preferable to instantiate a single `Timer` and reuse it,
	  as shown in the following example:
	  ---
	  void myPollingFunction () {
		  Timer waiter = createTimer(null); // Create a re-usable timer
		  while (true) {
			  // Your awesome code goes here
			  timer.rearm(timeout, false);
			  timer.wait();
		  }
	  }
	  ---

	Throws: May throw an `InterruptException` if the task gets interrupted using
		`Task.interrupt()`.
*/
void sleep(Duration timeout)
@safe {
	assert(timeout >= 0.seconds, "Argument to sleep must not be negative.");
	if (timeout <= 0.seconds) return;
	delay(timeout);
}
///
unittest {
	import vibe.core.core : sleep;
	import vibe.core.log : logInfo;
	import core.time : msecs;

	void test()
	{
		logInfo("Sleeping for half a second...");
		sleep(500.msecs);
		logInfo("Done sleeping.");
	}
}

shared TaskPool workerTaskPool;
shared TaskPool ioWorkerTaskPool;

shared static this() {
	workerTaskPool = new TaskPool;
	ioWorkerTaskPool = new TaskPool;
}

/** Suspends the execution of the calling task an an uninterruptible manner.

	This function behaves the same as `sleep`, except that invoking
	`Task.interrupt` on the calling task will not result in an
	`InterruptException` being thrown from `sleepUninterruptible`. Instead,
	if any, a later interruptible wait state will throw the exception.
*/
void sleepUninterruptible(Duration timeout)
@safe nothrow {
	assert(timeout >= 0.seconds, "Argument to sleep must not be negative.");
	if (timeout <= 0.seconds) return;
	delay(timeout);
}


/**
	Creates a new timer, that will fire `callback` after `timeout`

	Timers can be be separated into two categories: one-off or periodic.
	One-off timers fire only once, after a specific amount of time,
	while periodic timer fire at a regular interval.

	One-off_timers:
	One-off timers can be used for performing a task after a specific delay,
	or to schedule a time without interrupting the currently running code.
	For example, the following is a way to emulate a 'schedule' primitive,
	a way to schedule a task without starting it immediately (unlike `runTask`):
	---
	void handleRequest (scope HTTPServerRequest req, scope HTTPServerResponse res) {
		Payload payload = parse(req);
		if (payload.isValid())
		  // Don't immediately yield, finish processing the data and the query
		  setTimer(0.msecs, () => sendToPeers(payload));
		process(payload);
		res.writeVoidBody();
	}
	---

	In this example, the server delays the network communication that
	will be	 performed by `sendToPeers` until after the request is fully
	processed, ensuring the client doesn't wait more than the actual processing
	time for the response.

	Periodic_timers:
	Periodic timers will trigger for the first time after `timeout`,
	then at best every `timeout` period after this. Periodic timers may be
	explicitly stopped by calling the `Timer.stop()` method on the return value
	of this function.

	As timer are non-preemtive (see the "Preemption" section), user code does
	not need to compensate for time drift, as the time spent in the function
	will not affect the frequency, unless the function takes longer to complete
	than the timer.

	Preemption:
	Like other events in Vibe.d, timers are non-preemptive, meaning that
	the currently executing function will not be interrupted to let a timer run.
	This is usually not a problem in server applications, as any blocking code
	will be easily noticed (the server will stop to handle requests), but might
	come at a surprise in code that doesn't handle request.
	If this is a problem, the solution is usually to either explicitly give
	control to the event loop (by calling `yield`) or ensuring operations are
	asynchronous (e.g. call functions from `vibe.core.file` instead of `std.file`).

	Reentrancy:
	The event loop guarantees that the same timer will never be called more than
	once at a time. Hence, functions run on a timer do not need to be re-entrant,
	even if they execute for longer than the timer frequency.

	Params:
		timeout = Determines the minimum amount of time that elapses before the timer fires.
		callback = A delegate to be called when the timer fires. Can be `null`,
				   in which case the timer will not do anything.
		periodic = Speficies if the timer fires repeatedly or only once

	Returns:
		Returns a `Timer` object that can be used to identify and modify the timer.

	See_also: `createTimer`
*/
Timer setTimer(Duration timeout, Timer.Callback callback, bool periodic = false)
@safe nothrow {
	auto tm = createTimer(callback);
	//tm.rearm(timeout, periodic); //TODO: implement timers
	return tm;
}
///
unittest {
	void printTime()
	@safe nothrow {
		import std.datetime;
		logInfo("The time is: %s", Clock.currTime());
	}

	void test()
	{
		import vibe.core.core;
		// start a periodic timer that prints the time every second
		setTimer(1.seconds, toDelegate(&printTime), true);
	}
}

/// Compatibility overload - use a `@safe nothrow` callback instead.
Timer setTimer(Duration timeout, void delegate() callback, bool periodic = false)
@system nothrow {
	return setTimer(timeout, () @trusted nothrow {
		try callback();
		catch (Exception e) {
			e.logException!(LogLevel.warn)("Timer callback failed");
		}
	}, periodic);
}
/+
unittest { // make sure that periodic timer calls never overlap
	int ccount = 0;
	int fcount = 0;
	Timer tm;

	tm = setTimer(10.msecs, {
		ccount++;
		scope (exit) ccount--;
		assert(ccount == 1); // no concurrency allowed
		assert(fcount < 5);
		sleep(100.msecs);
		if (++fcount >= 5)
			tm.stop();
	}, true);

	while (tm.pending) sleep(50.msecs);

	sleep(50.msecs);

	assert(fcount == 5);
}
+/

/** Creates a new timer without arming it.

	Each time `callback` gets invoked, it will be run inside of a newly started
	task.

	Params:
		callback = If non-`null`, this delegate will be called when the timer
			fires

	See_also: `createLeanTimer`, `setTimer`
*/
Timer createTimer(void delegate() nothrow @safe callback = null)
@safe nothrow {
	return timer(); //TODO implement proper timers in photon
}


/** Creates a new timer with a lean callback mechanism.

	In contrast to the standard `createTimer`, `callback` will not be called
	in a new task, but is instead called directly in the context of the event
	loop.

	For this reason, the supplied callback is not allowed to perform any
	operation that needs to block/yield execution. In this case, `runTask`
	needs to be used explicitly to perform the operation asynchronously.

	Additionally, `callback` can carry arbitrary state without requiring a heap
	allocation.

	See_also: `createTimer`
*/
Timer createLeanTimer(CALLABLE)(CALLABLE callback)
	if (is(typeof(() @safe nothrow { callback(); } ()))
		|| is(typeof(() @safe nothrow { callback(Timer.init); } ())))
{
	return timer(); // TODO implement proper timers in photon
}

/**
	Sets the stack size to use for tasks.

	The default stack size is set to 512 KiB on 32-bit systems and to 16 MiB
	on 64-bit systems, which is sufficient for most tasks. Tuning this value
	can be used to reduce memory usage for large numbers of concurrent tasks
	or to avoid stack overflows for applications with heavy stack use.

	Note that this function must be called at initialization time, before any
	task is started to have an effect.

	Also note that the stack will initially not consume actual physical memory -
	it just reserves virtual address space. Only once the stack gets actually
	filled up with data will physical memory then be reserved page by page. This
	means that the stack can safely be set to large sizes on 64-bit systems
	without having to worry about memory usage.
*/
void setTaskStackSize(size_t sz)
nothrow {
	// TaskFiber.ms_taskStackSize = sz;
	// noop
}


/**
	The number of worker threads used for processing worker tasks.

	Note that this function will cause the worker threads to be started,
	if they haven't	already.

	See_also: `runWorkerTask`, `runWorkerTaskH`, `runWorkerTaskDist`,
	`setupWorkerThreads`
*/
@property size_t workerThreadCount() nothrow
	out(count) { assert(count > 0, "No worker threads started after setupWorkerThreads!?"); }
do {
	return schedulerThreads(); // TODO: expose from photon
}


/**
	Disables the signal handlers usually set up by vibe.d.

	During the first call to `runEventLoop`, vibe.d usually sets up a set of
	event handlers for SIGINT, SIGTERM and SIGPIPE. Since in some situations
	this can be undesirable, this function can be called before the first
	invocation of the event loop to avoid this.

	Calling this function after `runEventLoop` will have no effect.
*/
void disableDefaultSignalHandlers()
{
	//noop
}

/**
	Sets the effective user and group ID to the ones configured for privilege lowering.

	This function is useful for services run as root to give up on the privileges that
	they only need for initialization (such as listening on ports <= 1024 or opening
	system log files).
*/
void lowerPrivileges(string uname, string gname)
@safe {
	/*
	if (!isRoot()) return;
	if (uname != "" || gname != "") {
		static bool tryParse(T)(string s, out T n)
		{
			import std.conv, std.ascii;
			if (!isDigit(s[0])) return false;
			n = parse!T(s);
			return s.length==0;
		}
		int uid = -1, gid = -1;
		if (uname != "" && !tryParse(uname, uid)) uid = getUID(uname);
		if (gname != "" && !tryParse(gname, gid)) gid = getGID(gname);
		setUID(uid, gid);
	} else logWarn("Vibe was run as root, and no user/group has been specified for privilege lowering. Running with full permissions.");
	*/
}

// ditto
void lowerPrivileges()
@safe {
	//lowerPrivileges(s_privilegeLoweringUserName, s_privilegeLoweringGroupName);
}

/**
	A version string representing the current vibe.d core version
*/
enum vibeVersionString = "2.12.0";


/** Returns an object that ensures that no task switches happen during its life time.

	Any attempt to run the event loop or switching to another task will cause
	an assertion to be thrown within the scope that defines the lifetime of the
	returned object.

	Multiple yield locks can appear in nested scopes.
*/
auto yieldLock(string file = __FILE__, int line = __LINE__)
@safe nothrow {
	static struct YieldLock {
	}

	return YieldLock();
}


/** Less strict version of `yieldLock` that only locks if called within a task.
*/
auto taskYieldLock(string file = __FILE__, int line = __LINE__)
@safe nothrow {
	return yieldLock(file, line);
}
