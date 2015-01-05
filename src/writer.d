/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl., Ferdinand Majerech
 * Authors: Brian Schott, Ferdinand Majerech
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module writer;


import config;
import ddoc.comments;
import formatter;
import std.algorithm;
import std.array: appender, empty, array, back;
import std.d.ast;
import std.stdio;
import std.string: format;
import std.typecons;
import tocbuilder: TocItem;


class HTMLWriter
{
	/** Construct a HTMLWriter.
	 *
	 * Params:
	 *
	 * config        = Configuration data, including macros and the output directory.
	 * macros        = DDoc macro definitions indexed by macro name.
	 * searchIndex   = A file where the search information will be written
	 * tocItems      = Items of the table of contents to write into each documentation file.
	 * tocAdditional = Additional content for the table of contents sidebar.
	 */
	this(ref const Config config, string[string] macros, File searchIndex,
	     TocItem[] tocItems, string tocAdditional)
	{
		this.config = &config;
		this.macros = macros;
		this.searchIndex = searchIndex;
		this.tocItems = tocItems;
		this.tocAdditional = tocAdditional;
	}

	/** Writes HTML header information to the given range.
	 *
	 * Params:
	 *
	 * dst   = Range to write to
	 * title = The content of the HTML "title" element
	 * depth = The directory depth of the file. This is used for ensuring that
	 *         the "base" element is correct so that links resolve properly.
	 */
	void writeHeader(R)(ref R dst, string title, size_t depth)
	{
		import std.range: repeat;
		const rootPath = "../".repeat(depth).joiner.array;
		dst.put(
`<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<link rel="stylesheet" type="text/css" href="%sstyle.css"/>
<script src="%shighlight.pack.js"></script>
<title>%s</title>
<base href="%s"/>
<script src="search.js"></script>
<script src="show_hide.js"></script>
</head>
<body>
<div class="main">
`.format(rootPath, rootPath, title, rootPath));
	}

	/** Writes the table of contents to provided range.
	 *
	 * Params:
	 *
	 * dst        = Range to write to.
	 * moduleName = Name of the module or package documentation page of which we're
	 *              writing the TOC for.
	 */
	void writeTOC(R)(ref R dst, string moduleName = "")
	{
		void put(string str) { dst.put(str); dst.put("\n"); }
		put(`<div class="toc">`);
		if(tocAdditional !is null)
		{
			put(`<div class="toc-additional">`);
			put(tocAdditional);
			put(`</div>`);
		}
		put(`<ul>`);
		foreach (t; tocItems)
			t.write(dst, moduleName);
		put(`</ul>`);
		put(`</div>`);
	}

	/** Writes navigation breadcrumbs to the given range.
	 *
	 * Also starts the "content" <div>; must be called after writeTOC(), before writing
	 * main content.
	 *
	 * Params:
	 *
	 * dst     = Range (e.g. appender) to write to.
	 * heading = Page heading (e.g. module name or "Main Page").
	 */
	void writeBreadcrumbs(R)(R dst, string heading)
	{
		void put(string str) { dst.put(str); dst.put("\n"); }
		put(`<div class="breadcrumbs">`);
		put(`<table id="results"></table>`);
		put(`<a class="home" href=index.html>⌂</a>`);
		put(`<input type="search" id="search" placeholder="Search" onkeyup="searchSubmit(this.value, event)"/>`);
		put(heading);
		put(`</div>`);
		put(`<div class="content">`);
	}

	/** Writes navigation breadcrumbs for a symbol's documentation file.
	 *
	 * Params:
	 *
	 * dst              = Range to write to.
	 * moduleNameLength = Name length of the module this symbol is in (e.g. 2 for std.stdio)
	 * symbolStack      = Name stack of the current symbol, including module name parts.
	 */
	void writeBreadcrumbs(R)(ref R dst, size_t moduleNameLength, const string[] symbolStack)
	{
		import std.array : join;
		import std.conv : to;
		import std.range : chain, only;
		import std.string: format;
		
		string heading;
		scope(exit) { writeBreadcrumbs(dst, heading); }

		assert(moduleNameLength <= symbolStack.length, "stack shallower than the current module?");
		size_t i;
		import std.path: buildPath;
		
		string link() { return symbolStack[0 .. i + 1].buildPath() ~ ".html"; }

		// Module
		{
			heading ~= "<small>";
			scope(exit) { heading ~= "</small>"; }
			for(; i + 1 < moduleNameLength; ++i)
			{
				heading ~= symbolStack[i] ~ ".";
			}
			// Module link if the module is a parent of the current page.
			if(i + 1 < symbolStack.length)
			{
				heading ~= `<a href=%s>%s</a>.`.format(link(), symbolStack[i]);
				++i;
			}
			// Just the module name, not a link, if we're at the module page.
			else
			{
				heading ~= symbolStack[i];
				return;
			}
		}

		// Class/Function/etc. in the module
		heading ~= `<span class="highlight">`;
		// The rest of the stack except the last element (parents of current page).
		for(; i + 1 < symbolStack.length; ++i)
		{
			heading  ~= `<a href=%s>%s</a>.`.format(link(), symbolStack[i]);
		}
		// The last element (no need to link to the current page).
		heading ~= symbolStack[i];
		heading ~= `</span>`;
	}


	/** Writes a doc comment to the given range and returns the summary text.
	 *
	 * Params:
	 * dst          = Range to write the comment to.
	 * comment      = The comment to write
	 * prevComments = Previously encountered comments. This is used for handling
	 *                "ditto" comments. May be null.
	 * functionBody = A function body used for writing contract information. May be null.
	 * testdocs     = Pairs of unittest bodies and unittest doc comments. May be null.
	 *
	 * Returns: the summary from the given comment
	 */
	string readAndWriteComment(R)
		(ref R dst, string comment, Comment[] prevComments = null,
		 const FunctionBody functionBody = null,
		 Tuple!(string, string)[] testDocs = null)
	{
		import std.d.lexer : unDecorateComment;
		auto app = appender!string();
		comment.unDecorateComment(app);
	//	writeln(comment, " undecorated to ", app.data);

		Comment c = parseComment(app.data, macros);
		immutable ditto = c.isDitto;

		// Run sections through markdown.
		foreach(ref section; c.sections) 
		{
			import dmarkdown;
			// Ensure param descriptions run through Markdown
			if(section.name == "Params")
			{
				foreach(ref kv; section.mapping)
				{
					kv[1] = filterMarkdown(kv[1], MarkdownFlags.alternateSubheaders);
				}
			}
			// Do not run code examples through markdown.
			//
			// We could also check for section.name == "Examples" but code blocks can
			// be even outside examples. Alternatively, we could look for *multi-line*
			// <pre>/<code> blocks, or, before parsing comments, for "---" pairs.
			//
			// Alternatively, dmarkdown could be changed to ignore <pre>/<code>
			// blocks.
			if(!section.content.canFind("<pre><code>")) 
			{
				section.content = filterMarkdown(section.content,
					MarkdownFlags.alternateSubheaders);
			}
		}

		if (prevComments.length > 0)
		{
			if (ditto)
				c = prevComments[$ - 1];
			else
				prevComments[$ - 1] = c;
		}
		
		
		writeComment(dst, c, functionBody);

		// Shortcut to write text followed by newline
		void put(string str) { dst.put(str); dst.put("\n"); }
		// Find summary and return value info
		string rVal = "";
		if (c.sections.length && c.sections[0].name == "Summary")
			rVal = c.sections[0].content;
		else
		{
			foreach (section; c.sections)
			{
				if (section.name == "Returns")
					rVal = "Returns: " ~ section.content;
			}
		}
		if (testDocs !is null) foreach (doc; testDocs)
		{
	//		writeln("Writing a unittest doc comment");
			import std.string : outdent;
			put(`<div class="section"><h2>Example</h2>`);
			auto docApp = appender!string();
			doc[1].unDecorateComment(docApp);
			Comment dc = parseComment(docApp.data, macros);
			writeComment(dst, dc);
			writeCodeBlock(dst, { dst.put(outdent(doc[0])); } );
			put(`</div>`);
		}
		return rVal;
	}


	/** Writes attributes to the range dst using formatter to format code.
	 *
	 * Params:
	 *
	 * dst       = Range to write to.
	 * formatter = Formatter to format the attributes with.
	 * attrs     = Attributes to write.
	 */
	void writeAttributes(R, F)(ref R dst, F formatter, const(Attribute)[] attrs)
	{
		import std.d.lexer: IdType, isProtection, tok;
		IdType protection;
		foreach (a; attrs.filter!(a => a.attribute.type.isProtection))
		{
			protection = a.attribute.type;
		}
		switch (protection)
		{
			case tok!"private":   dst.put("private ");   break;
			case tok!"package":   dst.put("package ");   break;
			case tok!"protected": dst.put("protected "); break;
			default:              dst.put("public ");    break;
		}
		foreach (a; attrs.filter!(a => !a.attribute.type.isProtection))
		{
			formatter.format(a);
			dst.put(" ");
		}
	}

	/** Writes a code block to range dst, using blockCode to write code block
	 * contents.
	 *
	 * Params:
	 *
	 * dst       = Range to write to.
	 * blockCode = Function that will write the code block contents (presumably also
	 *             into dst).
	 */
	void writeCodeBlock(R)(ref R dst, void delegate() blockCode)
	{
		dst.put(`<pre><code>`);
		blockCode();
		dst.put("\n");
		dst.put(`</code></pre>`);
		dst.put("\n");
	}

	/** Formats an AST node to a string.
	 */
	static string formatNode(T)(const T t)
	{
		auto writer = appender!string();
		auto formatter = new HarboredFormatter!(typeof(writer))(writer);
		formatter.format(t);
		return writer.data;
	}

	void addSearchEntry(string moduleFileBase, size_t moduleNameLength, string[] symbolStack)
	{
		import std.path: buildPath;
		import std.conv: to;
		
		const symbol = symbolStack.joiner(".").array;
		const symbolInModule = symbolStack[moduleNameLength .. $].joiner(".").array;
		const fileName = moduleFileBase.buildPath(symbolInModule.to!string) ~ ".html";
		searchIndex.writefln(`{"%s" : "%s"},`, symbol, fileName);
	}

private:
	void writeComment(R)(ref R dst, Comment comment, const FunctionBody functionBody = null)
	{
	//		writeln("writeComment: ", comment.sections.length, " sections.");
		// Shortcut to write text followed by newline
		void put(string str) { dst.put(str); dst.put("\n"); }

		size_t i;
		for (i = 0; i < comment.sections.length && (comment.sections[i].name == "Summary"
			|| comment.sections[i].name == "description"); i++)
		{
			put(`<div class="section">`);
			put(comment.sections[i].content);
			put(`</div>`);
		}

		if (functionBody !is null)
		{
			writeContracts(dst, functionBody.inStatement, functionBody.outStatement);
		}


		const seealsoNames = ["See_also", "See_Also", "See also", "See Also"];
		foreach (section; comment.sections[i .. $])
		{
			if (seealsoNames.canFind(section.name) || section.name == "Macros")
				continue;

			// Note sections a use different style
			const isNote = section.name == "Note";
			string extraClasses;

			if(isNote)
				extraClasses ~= " note";

			put(`<div class="section%s">`.format(extraClasses));
			if (section.name != "Summary" && section.name != "Description")
			{
				dst.put("<h2>");
				dst.put(prettySectionName(section.name));
				put("</h2>");
			}
			if(isNote)
				put(`<div class="note-content">`);
			if (section.name == "Params")
			{
				put(`<table class="params">`);
				foreach (kv; section.mapping)
				{
					dst.put(`<tr class="param"><td class="paramName">`);
					dst.put(kv[0]);
					dst.put(`</td><td class="paramDoc">`);
					dst.put(kv[1]);
					put("</td></tr>");
				}
				dst.put("</table>");
			}
			else
			{
				put(section.content);
			}
			if(isNote)
				put(`</div>`);
			put(`</div>`);
		}

		// Merge any see also sections into one, and draw it with different style than
		// other sections.
		{
			auto seealsos = comment.sections.filter!(s => seealsoNames.canFind(s.name));
			if(!seealsos.empty)
			{
				put(`<div class="section seealso">`);
				dst.put("<h2>");
				dst.put(prettySectionName(seealsos.front.name));
				put("</h2>");
				put(`<div class="seealso-content">`);
				foreach(section; seealsos)
				{
					put(section.content);
				}
				put(`</div>`);
				put(`</div>`);
			}
		}
	}

	void writeContracts(R)(ref R dst, const InStatement inStatement,
		const OutStatement outStatement)
	{
		if (inStatement is null && outStatement is null)
			return;
		dst.put(`<div class="section"><h2>Contracts</h2>`);
		writeCodeBlock(dst, {
			auto formatter = new HarboredFormatter!R(dst);
			scope(exit) formatter.sink = R.init;
			if (inStatement !is null)
			{
				formatter.format(inStatement);
				if (outStatement !is null)
					dst.put("\n");
			}
			if (outStatement !is null)
				formatter.format(outStatement);
		});
		dst.put("</div>\n");
	}


private:
	const(Config)* config;
	string[string] macros;
	File searchIndex;
	TocItem[] tocItems;
	string tocAdditional;
}


string prettySectionName(string sectionName)
{
	switch (sectionName)
	{
		case "See_also", "See_Also", "See also", "See Also": return "See Also:";
		case "Note":   return "Note:";
		case "Params": return "Parameters";
		default:       return sectionName;
	}
}