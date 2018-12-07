# enTangleD: a bi-directional literate programming tool

Literate programming is awesome! Write your documentation and code in one markdown document, tangle the source code from that document, compile and run your code. But ow what happens? Compiler error? Bug? Where? Your debugger is no longer pointing to your real source file! No worries, just edit the source file first, fix the bug and then copy the edits to your master document. Meh.

Enter enTangleD! This monitors the tangled source files and reflects any change in master document or source files in one live source database. The markdown file is still the master document.

## Status

`enTangleD` is working, but still in a premature stage. It currently only works on Linux due to a dependency on INotify. If you edit anything serious with the enTangle Daemon running, I strongly recommend using version control and commit often. If you encounter unexpected behaviour, please post an issue and describe the steps to reproduce.

Features:
* live bi-directional updates
* monitor multiple markdown files
* PanDoc filter and `Makefile` to generate report

Todo:
* watch containing folder for changes
* configurability using Yaml file
* robustness against wrongly edited output files
* integration with git: commit every change, squash when done
* add workflow to create figures for HTML/PDF reports
* MacOS / Windows version

## Building

`enTangleD` is written in Haskell. You can build an executable by running

    stack build

Install the executable in your `~/.local/bin`

    stack install

Run unit tests

    stack test

## Syntax (markdown side)

The markdown syntax `enTangleD` uses is compatible with `Pandoc`'s.
This relies on the use of *fenced code attributes*. To tangle a code block to a file:

~~~markdown
``` {.bash file=src/count.sh}
   ...
```
~~~

Composing a file using multiple code blocks is done through *noweb* syntax. You can reference a named code block in another code block by putting something like `<<named-code-block>>` on a single line. This reference may be indented. Such an indentation is then prefixed to each line in the final result.

A named code block is should have an identifier given:

~~~markdown
``` {.python #named-code-block}
   ...
```
~~~

## Syntax (source side)

In the source code we know exactly where the code came from, so there would be no strict need for extra syntax there. However, once we start to edit the source file it may not be clear where the extra code needs to end up. To make our life a little easier, named code blocks that were tangled into the file are marked with a comment at begin and end.

```cpp
// _____ begin <<main-body>>[0]
std::cout << "Hello, World!" << std::endl;
// _____ end
```

These comments should not be tampered with!

## Configuration

> Not yet implemented: The project should contain a `tangle.yaml` file.
