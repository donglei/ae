﻿/**
 * HTTP / mail / etc. headers
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.net.ietf.headers;

import std.algorithm;
import std.string;
import std.ascii;
import std.exception;

/// AA-like superset structure with the purpose of maintaining
/// compatibility with the old HTTP string[string] headers field
struct Headers
{
	struct Header { string name, value; }

	// All keys are internally upper-case.
	private Header[][string] headers;

	/// If multiple headers with this name are present,
	/// only the first one is returned.
	ref inout(string) opIndex(string name) inout
	{
		return headers[toUpper(name)][0].value;
	}

	string opIndexAssign(string value, string name)
	{
		headers[toUpper(name)] = [Header(name, value)];
		return value;
	}

	inout(string)* opIn_r(string name) inout
	{
		auto pvalues = toUpper(name) in headers;
		if (pvalues && (*pvalues).length)
			return &(*pvalues)[0].value;
		return null;
	}

	void remove(string name)
	{
		headers.remove(toUpper(name));
	}

	// D forces these to be "ref"
	int opApply(int delegate(ref string name, ref string value) dg)
	{
		int ret;
		outer:
		foreach (key, values; headers)
			foreach (header; values)
			{
				ret = dg(header.name, header.value);
				if (ret)
					break outer;
			}
		return ret;
	}

	// Copy-paste because of https://issues.dlang.org/show_bug.cgi?id=7543
	int opApply(int delegate(ref const(string) name, ref const(string) value) dg) const
	{
		int ret;
		outer:
		foreach (name, values; headers)
			foreach (header; values)
			{
				ret = dg(header.name, header.value);
				if (ret)
					break outer;
			}
		return ret;
	}

	void add(string name, string value)
	{
		auto key = toUpper(name);
		if (key !in headers)
			headers[key] = [Header(name, value)];
		else
			headers[key] ~= Header(name, value);
	}

	string get(string key, string def) const
	{
		return getLazy(key, def);
	}

	string getLazy(string key, lazy string def) const
	{
		auto pvalue = key in this;
		return pvalue ? *pvalue : def;
	}

	inout(string)[] getAll(string key) inout
	{
		inout(string)[] result;
		foreach (header; headers.get(toUpper(key), null))
			result ~= header.value;
		return result;
	}

	/// Warning: discards repeating headers
	string[string] opCast(T)() const
		if (is(T == string[string]))
	{
		string[string] result;
		foreach (key, value; this)
			result[key] = value;
		return result;
	}

	string[][string] opCast(T)() inout
		if (is(T == string[][string]))
	{
		string[][string] result;
		foreach (k, v; this)
			result[k] ~= v;
		return result;
	}
}

unittest
{
	Headers headers;
	headers["test"] = "test";

	void test(T)(T headers)
	{
		assert("TEST" in headers);
		assert(headers["TEST"] == "test");

		foreach (k, v; headers)
			assert(k == "test" && v == "test");

		auto aas = cast(string[string])headers;
		assert(aas == ["test" : "test"]);

		auto aaa = cast(string[][string])headers;
		assert(aaa == ["test" : ["test"]]);
	}

	test(headers);

	const constHeaders = headers;
	test(constHeaders);
}

/// Normalize capitalization
string normalizeHeaderName(string header)
{
	alias std.ascii.toUpper toUpper;
	alias std.ascii.toLower toLower;

	auto s = header.dup;
	auto segments = s.split("-");
	foreach (segment; segments)
	{
		foreach (ref c; segment)
			c = cast(char)toUpper(c);
		switch (segment)
		{
			case "ID":
			case "IP":
			case "NNTP":
			case "TE":
			case "WWW":
				continue;
			case "ETAG":
				segment[] = "ETag";
				break;
			default:
				foreach (ref c; segment[1..$])
					c = cast(char)toLower(c);
				break;
		}
	}
	return assumeUnique(s);
}

unittest
{
	assert(normalizeHeaderName("X-ORIGINATING-IP") == "X-Originating-IP");
}
