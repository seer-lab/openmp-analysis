include "C18/c.grm"
include "C18/c-comments.grm"

% isParallelizable
% This program checks 3 steps to determine if a for loop is parallelizable
% 1. match for loop
% 2. check that loop is pragma-compatible (structured block)
% 3. check that written-to variables are not referenced in other iterations

% Usage instructions:
% 1. have c code, with at least one for loop
% 2. before the for loop you want to test, add this comment: //@omp-analysis=true
% 3. run: txl isParallelizable.txl [c code filepath] -comment
%       - without full program output: txl isParallelizable.txl [c code filepath] -comment -q -o /dev/null


%_____________ redefine/define necessary patterns _____________

% redefine block_item to include comments
%redefine block_item
%    ...
%    | [comment] [NL]
%    | [comment]
%end redefine
%redefine function_definition_or_declaration
%    ...
%    | [comment] [NL]
%    | [comment]
%end redefine

% define comment_for for easier parsing of for loops preceded by annotation
define comment_for
    [comment] [NL]
    [attr srclinenumber] [for_statement]
end redefine

redefine for_statement
    ...
    | [comment_for]
end redefine


%redefine block_item
%    [attr srclinenumber] [declaration_or_statement]
%end redefine

%redefine declaration
%	...
%    |	[comment]
%end redefine



%_____________ main: apply functions/rules to entire program _____________

function main
    replace [program]
        p [program]
    export assignedToElements [repeat unary_expression]
        _
    by
        p [checkForParallel]
end function



%_____________ master parallelizable-check function _____________

% check if for loop can be parallelized
rule checkForParallel
    replace $ [comment_for]
        cf [comment_for]
    deconstruct cf
        '//@omp-analysis=true
        ln [srclinenumber] f [for_statement]
    construct message1 [stringlit]
        _ [+ "Analyzing for loop on line "] [quote ln] [+ ": "] [message ""] [print] [message f] [message ""]
    deconstruct f
        'for '( nnd [opt non_null_declaration] el1 [opt expression_list] '; el2 [opt expression_list] soel [opt semi_opt_expression_list] ') ss [sub_statement]
    deconstruct ss 
        % this deconstruction of substatement only works with 
        % block surrounded by { and }, not a single line for loop (TODO: support single-line-block for loops)
        '{ b [repeat block_item] '}
    where not
        b [subScopeNotCompatible]
    %construct message2 [repeat any]
    %    _   [message ""]
    %        [message "Loop passed pragma compatibility test (step 2)"] 
    %        [message ""]
    %        [message "reference-test process:"]
    %        [message " - collecting assigned-to elements"]
    construct message3 [repeat block_item]
        b [storeAssignedToElements] %[message " - stored assigned-to elements"]
    %construct message4 [repeat any]
    %    _ [message " - iterating through referenced elements: checking for assigned-to elements"] [message ""]
    construct collapseTest [repeat block_item]
        b [canBeCollapsed]
    where not
        b [isReferencedElementAssignedTo]
    %construct message5 [repeat any]
    %    _ [message ""] [message "Passed reference-test (step 3)"]
    %construct nf [for_statement]
    %    'for '( nnd el1 '; el2 soel ') '{ b '}
    by
        cf [message "No parallelization problems found with this loop."]
end rule



%_____________ check if for loop is nested and can be collapsed _____________
function canBeCollapsed
    match $ [repeat block_item]
        b [repeat block_item]
    where
        b [containsForLoop]
    where not
        b [containsNonForLoop]
    construct canBeCollapsedMessage [repeat any]
        _ [message "This for loop can use the collapse construct."]
end function

function containsNonForLoop
    match $ [repeat block_item]
        b [repeat block_item]
    where
        b [checkForNonForLoop]
    construct cantBeCollapsedMessage [repeat any]
        _ [message "This for loop cannot use the collapse construct without refactoring."]
end function

rule checkForNonForLoop
    % ignore nested loop scope
    skipping [sub_statement]
    match $ [block_item]
        bi [block_item]
    where not
        bi [isForLoop]
    where not
        bi [containsComment]
    %construct comment [stringlit]
    %    _ [+ "nonForLoop, line: "] [quote bi] [print]
end rule

rule containsForLoop
    match $ [block_item]
        fs [for_statement]
end rule

function isForLoop
    match $ [block_item]
        fs [for_statement]
end function

function containsComment
    match $ [block_item]
        c [comment]
end function



%_____________ check referenced _____________


% check block for referenced elements which are assigned to
function isReferencedElementAssignedTo
    skipping [subscript_extension]
    match $ [repeat block_item]
        b [repeat block_item]
    where
        b   [isAssignedTo]
            [isAssignedTo_AssignmentReference]
end function

% subrule: check for referenced elements which are assigned to in block
rule isAssignedTo
    match $ [block_item]
        b [block_item]
    deconstruct not b % assignment expressions are checked in other subrule
        ce [conditional_expression] aae [assign_assignment_expression] ';
    where
        b [elementIsAssignedTo]
    construct message [stringlit]
        _ [+ "    on line: "] [quote b] [print]
end rule

% subrule: check assignment expressions for referenced elements which are assigned to
rule isAssignedTo_AssignmentReference
    skipping [subscript_extension]
    match $ [assignment_expression]
        ae [assignment_expression]
    deconstruct ae
        ce [conditional_expression] aae [assign_assignment_expression]
    where
        aae [elementIsAssignedTo]
    %construct message [stringlit]
    %    _ [+ "    on line: "] [quote ae] [print] [message ""] [message ""]
end rule

% check if element is in list of unary expressions
rule elementIsAssignedTo
    import assignedToElements [repeat unary_expression]
    match $ [unary_expression]
        e [unary_expression]
    where
        assignedToElements [isInRepeat e]
end rule

rule isInRepeat e [unary_expression]
    skipping [unary_expression] % so expressions like a[i] don't match i
    match * [unary_expression]
        e1 [unary_expression]
    where
        e1 [= e]
    construct message [stringlit]
        _   [message ""]
            [+ "This location is written to and read on different iterations: "] 
            [quote e1]
            [print]
            [message "This may mean the loop cannot be parallelized or must be refactored before being parallelized."]
    %construct message2 [stringlit]
    %    _ [quote e1] [print]
end rule
    


%_____________ store assigned-to elements in a list _____________

%  store print each assignment expression in scope
rule storeAssignedToElements
    replace $ [assignment_expression]
        ae1 [assignment_expression]
    deconstruct ae1
        ce [unary_expression] aae [assign_assignment_expression]
    construct ae [assignment_expression]
        ce [addAssignedToElement] aae
    by 
        ae
end rule

% function to add assigned-to element to list
function addAssignedToElement
    import assignedToElements [repeat unary_expression]
    match [unary_expression]
        newEntry [unary_expression]
    %construct message1 [stringlit]
    %    _ [+ "    found assigned-to element: "] [quote newEntry] [print]
    construct newAssignedToElements [repeat unary_expression]
        assignedToElements [. newEntry]
    export assignedToElements
        newAssignedToElements
end function



%_____________ check if subscope is compatible with pragmas _____________

% check if sub scope is compatible for pragmas/parallelization
rule subScopeNotCompatible
    match [block_item]
        b [block_item]
    where
        b [isJumpStatement]
end rule

% determine if line violates structured-block condition
function isJumpStatement
    match [block_item]
        j [jump_statement] s [semi]
    construct message1 [stringlit]
        _ [+ "This for loop is not currently parallelizable. A *"] [quote j] [+ "* statement makes the block non-structured: "] [print]
end function
