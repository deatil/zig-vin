pub const AstError = error{
    TemplateSyntaxError,
};

pub const LexerError = error{
    OutOfMemory,
    TemplateSyntaxError,
};

pub const ValueError = error{
    OutOfMemory,
    /// An operation that an undefined value does not support.
    UndefinedValue,
    /// Operand types the operator does not accept (Python `TypeError`).
    TypeMismatch,
    DivisionByZero,
    /// An integer left `i64`, or a construction exceeded a documented cap.
    OutOfRange,
    /// A filter/test/method argument was wrong in kind or count.
    BadArgument,
    /// Reached a corner this engine deliberately does not implement.
    Unsupported,
    /// for callable
    InvalidMethod,
    InvalidValue,
    InvalidExec,
    /// for return diag message
    DiagInvalidTemplateSyntax,
    DiagBadArgument,
};

pub const ParserError = error{
    OutOfMemory,
    TemplateSyntaxError,
    TooDeep,
};

pub const RenderError = ValueError || error{
    /// The output exceeded `Options.max_output_bytes`.
    OutputTooLarge,
    /// The render's total scratch allocation exceeded
    /// `Options.max_render_bytes`. Distinct from `OutOfMemory`: the machine
    /// has memory, this render asked for more than it is allowed.
    RenderBudgetExceeded,
    /// Called something that is not callable, or a method a value does not have.
    NotCallable,
    /// A filter/test named at compile time vanished from the registry.
    UnknownFilter,
    /// A composition tag named a template the loader does not have.
    TemplateNotFound,
    /// A composition tag was reached with no loader configured.
    NoLoader,
    /// `a extends b extends a` — caught structurally, before it can recurse.
    TemplateCycle,
    /// A depth cap was hit: template nesting, macro calls, or `loop()`.
    TooDeep,
    /// A loaded template failed to compile.
    TemplateSyntaxError,
    /// `{% block x required %}` reached without a derived template overriding
    /// it, or `{{ super() }}` with no parent definition.
    BlockError,
    /// A macro was called with arguments it does not accept.
    BadCall,
    /// The loader itself failed (I/O, size cap, a name it refuses).
    LoaderFailed,
    /// A loop body executed `{% continue %}`.
    LoopContinue,
    /// A loop body executed `{% break %}`.
    LoopBreak,
    /// A `{% while %}` tag exceeded `Options.max_while_iterations`.
    LoopLimitExceeded,
};

pub const LoaderError = error{
    OutOfMemory,
    /// The loader could not answer — an I/O failure, a file too large, a name
    /// the loader refuses. Distinct from "not found", which is `null`.
    LoaderFailed,
};
