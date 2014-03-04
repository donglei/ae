/**
 * Type serializer and deserializer.
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

module ae.utils.serialization.serialization;

import std.conv;
import std.string;

import ae.utils.meta;

/// Serialization sink which deserializes into a given type.
struct Deserializer(alias source)
{
	static template Impl(alias anchor)
	{
		alias C = source.Char;

		T deserialize(T)()
		{
			T t;
			auto sink = makeSink(&t);
			source.read(sink);
			return t;
		}

		mixin template SinkHandlers(T)
		{
			template unparseable(string inputType)
			{
				void unparseable(Reader)(Reader reader)
				{
					throw new Exception("Can't parse %s from %s".format(T.stringof, inputType));
				}
			}

			static if (is(T : C[]))
				void handleStringFragments(Reader)(Reader reader)
				{
					static struct FragmentSink
					{
						C[] buf;

						void handleStringFragment(CC)(CC[] s)
						{
							buf ~= s;
						}
					}
					FragmentSink sink;
					Reader.callWith(reader, parent, &sink);
					handleValue(sink.buf);
				}
			else
				alias handleStringFragments = unparseable!"string";

			static if (is(T U : U[]))
				void handleArray(Reader)(Reader reader)
				{
					auto sink = ArraySink!(U, Parent)(parent);
					Reader.callWith(reader, parent, boundObj(&sink));
					handleValue(sink.arr);
				}
			else
				alias handleArray = unparseable!"array";

			static if (is(T V : V[K], K))
				void handleObject(Reader)(Reader reader)
				{
					static struct FieldSink
					{
						Parent parent;
						T aa;

						void handleField(NameReader, ValueReader)(NameReader nameReader, ValueReader valueReader)
						{
							K k;
							V v;
							NameReader .callWith(nameReader , parent, __traits(child, parent, makeSink!K)(&k));
							ValueReader.callWith(valueReader, parent, __traits(child, parent, makeSink!V)(&v));
							aa[k] = v;
						}
					}

					auto sink = FieldSink(parent);
					Reader.callWith(reader, parent, boundObj(&sink));
					handleValue(sink.aa);
				}
			else
			static if (is(T == struct))
			{
				void handleObject(Reader)(Reader reader)
				{
					static struct FieldSink
					{
						Parent parent;
						T s;

						void handleField(NameReader, ValueReader)(NameReader nameReader, ValueReader valueReader)
						{
							alias N = const(C)[];
							N name;
							NameReader.callWith(nameReader, parent, __traits(child, parent, makeSink!N)(&name));

							// TODO: generate switch
							foreach (i, field; s.tupleof)
							{
								// TODO: Name customization UDAs
								enum fieldName = to!N(__traits(identifier, s.tupleof[i]));
								if (name == fieldName)
								{
									alias V = typeof(field);
									ValueReader.callWith(valueReader, parent, __traits(child, parent, makeSink!V)(&s.tupleof[i]));
									return;
								}
							}
							throw new Exception("Unknown field %s".format(name));
						}
					}

					auto sink = FieldSink(parent);
					Reader.callWith(reader, parent, boundObj(&sink));
					handleValue(sink.s);
				}
			}
			else
				alias handleObject = unparseable!"object";

			void handleNull()
			{
				static if (is(typeof({T v = null;})))
				{
					T v = null;
					handleValue(v);
				}
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "null"));
			}

			void handleBoolean(bool v)
			{
				static if (is(T : bool))
					handleValue(v);
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "boolean"));
			}

			void handleNumeric(C[] v)
			{
				static if (is(typeof(to!T(v))))
				{
					T t = to!T(v);
					handleValue(t);
				}
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "numeric"));
			}
		}

		static struct ArraySink(T, Parent)
		{
			Parent parent;
			T[] arr;

			void handleValue(ref T v) { arr ~= v; }

			mixin SinkHandlers!T;
		}

		auto makeSink(T)(T* p)
		{
			alias Parent = RefType!(typeof(this));

			static struct Sink
			{
				T* p;
				Parent parent;

				// TODO: avoid redundant copying for large types
				void handleValue(ref T v) { *p = v; }

				mixin SinkHandlers!T;
			}

			auto s = Sink(p, this.reference);
			return boundObj(s);
		}
	}
}

/// Serialization source which serializes a given object.
struct Serializer(alias writer)
{
	static template Impl(alias anchor)
	{
		void serialize(T)(auto ref T v)
		{
			auto sink = writer.createSink();
			read(sink, v);
		}

		static void read(Sink, T)(Sink sink, auto ref T v)
		{
			static if (is(typeof(v is null)))
				if (v is null)
				{
					sink.handleNull();
					return;
				}

			static if (is(T : ulong))
			{
				char[DecimalSize!T] buf = void;
				sink.handleNumeric(toDec(v, buf));
			}
			else
			static if (isNumeric!T) // floating point
			{
				import ae.utils.textout;

				static char[64] arr;
				auto buf = StringBuffer(arr);
				formattedWrite(&buf, "%s", v);
				sink.handleNumeric(buf.get());
			}
			else
			static if (is(T == struct))
			{
				static struct StructReader
				{
					RefType!T p;
					void read(Sink)(Sink sink)
					{
						foreach (i, ref field; p.dereference.tupleof)
						{
							import std.array : split;
							enum name = p.dereference.tupleof[i].stringof.split(".")[$-1];

							alias ValueReader = Reader!(typeof(field));
							auto reader = ValueReader(&field);
							sink.handleField(unboundDgAlias!(stringReader!name), boundDgAlias!(ValueReader.readValue)(&reader));
						}
					}
				}
				auto reader = StructReader(v.reference);
				sink.handleObject(boundDgAlias!(StructReader.read)(&reader));
			}
			else
			static if (is(T : string))
				sink.handleString(v);
			else
			static if (is(T U : U[]))
			{
				static struct ArrayReader
				{
					T arr;
					void readArray(Sink)(Sink sink)
					{
						foreach (ref v; arr)
							read(sink, v);
					}
				}
				auto reader = ArrayReader(v);
				sink.handleArray(boundDgAlias!(ArrayReader.readArray)(&reader));
			}
			else
			static if (is(T == bool))
				sink.handleBoolean(v);
			else
				static assert(false, "Don't know how to serialize " ~ T.stringof);
		}

		static template stringReader(string name)
		{
			static void stringReader(Sink)(Sink sink)
			{
				sink.handleString(name);
			}
		}

		static struct Reader(T)
		{
			T* p;

			void readValue(Sink)(Sink sink)
			{
				read(sink, *p);
			}
		}
	}
}
