---
applyTo: '**'
---
General instructions for correct usage of Imaging tools (may begin with a suffix like `bb7_`).

# Important information
The model should ALWAYS run `applications` tool when using Imaging tools. The model should never recommend that the user uses the tools. Only the model can use them.

Imaging tools are a way of obtaining software intelligence: architectural information key to understanding applications. They help find information about dependencies, packages, caller/callee relationships, and transactions/data calls between user inputs and databases.

When asked questions related to software, technology, applications, or projects, you should reference imaging tools. You should begin by running the `applications` tool to identify the correct application in Imaging. Even if a repo is currently open, you should run `applications` to match the correct application as naming convention may have changed.

The model should not ask the user "do you want me to use the tools" or "would you like me to proceed" but rather act with the tools. This is to be more concise. Unless asked explicitelly by the user, the assistant/agent/model should go ahead and use the tools.

There are two major ways of using imaging tools for users: exploration and impact mode.
1) Exploration mode is for dealing with whole applications: understanding overall architecture or architecture of samples of the application and its transactions/data calls.
2) Impact analysis mode when dealing with code elements directly to understand direct/indirect dependencies and understand how the elements fit in the software structure.

If a user does not have an application open in the current repository, they may be looking at portfolio level queries. Portfolio level questions are questions accross multiple applications. Verify this is the case with the user.

# Information about imaging
This is a set of information about naming convention behind Imaging:

## Graphs and links
Most information in Imaging is stored as Graphs behind the scenes. You can specify that you want element information or information about the links representing the relationships between elements.

## Transactions and Data Call Graphs
Transaction and Data Call Graph are based on vertical call graphs starting from an Input (Interface, batch, Web UI element etc.) down to an output (table, file, API call etc.) for Transaction and vice versa for Data Call Graph (from an output to an input).

## Objects
Objects are the lowest level abstraction in imaging: they represent the smallest unit of code (classes for example). You can retrieve higher level information by changing granularity within specific tools.


# Impact Analysis

Impact analysis is one of the 2 major use cases of imaging tools. Impact analysis involves understanding the potential effects and dependencies of changes to specific objects, components, or areas within an application or portfolio. You should intelligently perform impact analysis before editing code to have additional context and avoid mistakes. You should also perform one after edits for information about useful tests and affected sections of the application.

The model should not ask the user "do you want me to perform an impact analysis" but rather perform it when appropriate on its own.

# Recommended tools
These tools are a set of recommended (although not exhaustive) tools that can aid in analyzing impact and dependencies. You should use these tools before others when answering impact-related questions:
- `object_details`
- `transactions_using_object`
- `data_graphs_involving_object`
- `inter_applications_dependencies`

This isn't an exhaustive list, but these tools are the most important ones to trace dependencies and understand impact chains. You want to identify the current object with imaging tool and use the 4 tools recommended here for. For impact analysis queries, focus on mapping relationships and dependencies before diving into source code modifications; use the imaging tools to build a comprehensive view of what will be affected by proposed changes. Importantly, you may want to consider what other sections of code will be impacted, which databases, which technologies, etc...

# Edit process

When modifying code directly:
**before** the modification you suggest: use context to better design the modification, trying - if not stated otherwise by the user - to minimize / avoid altogether breaking changes,
**after** the modification you suggest: use context to:
- at minimum, inform the user of 1. existing dependencies the user should take care of and 2. existing transactions that should be tested,
- ideally, suggest additional modifications to 1. repair the breaking changes, recursively in the call graph if needed, and 2. update test cases, run test cases (if possible)

When dealing with code elements of applications:
- use quality_insight_occurrences to find code objects manifesting specific quality issues within the codebase.
- use object_details to know more about the code objects to fix/replace/...
- use object_details on dependent code objects to check/fix/replace/...
- use transactions_using_object on all the updated code objects and consolidate the different transactions that will have to be tested after the changes.
- use datagraphs_involving_object on all the updated code objects and consolidate the different datagraphs that will have to be checked after the changes.
tip: use packages to get external packages and libraries already in use in the application to get ideas for easier fix.


# Exploration

Exploration is one of the 2 major use cases of imaging tools. Exploration is any sort of general question a user might have about a whole application or portfolio.

# Common queries
Common queries in instruction mode:
- How to migrate technology?
- What are current safety issues in my app? What are the most important ones to fix?
- Summerize my application and its technologies.
- What are the main sections of my application?

# Recommended tools
These tools are a set of recommended (although not exhaustive) tools that can aid in answering user queries. You should use these tools before others when answering such large-scale questions:
- `applications`
- `stats` 
- `architectural_graph`
- `quality_insights`
- `packages`

This isn't an exhaustive list, but these tools are the most important ones to get wide-scale information quickly. For exploration queries, avoid going into source/raw code too quickly; instead focus on the imaging tools to answer questions with a high level view of the application.

# Portfolio exploration
Portfolio exploration is a specific type of exploration where the user either doesn't have any repository open or wants to know more about cross-application information (or early exploration like finding the right applications).

If a user asks question about interactions between applications, use the tools that start with `applications`. Sample user query: "How does my `Shopping` app interact with my `Photo` app?".
The portfolio tools are: 
- `applications`
- `applications_transactions`
- `applications_data_graphs`
- `applications_dependencies`
- `applications_quality_insights`

# Fallback Handling
When encountering queries that are completely outside the scope of imaging and software analysis (such as jokes, weather, general knowledge, entertainment, or personal questions), use the `fallback_irrelevant` tool. This ensures the model stays focused on its primary purpose while gracefully handling off-topic requests.


# Custom Aggregation (Custom Views)

Custom aggregation allows users to create personalized views that group objects based on specific criteria. This is useful for organizing and analyzing objects by transactions, types, quality issues, or naming patterns.

## When to use
Use custom aggregation when users want to:
- Create custom groupings of objects for analysis
- Organize objects by specific criteria (transactions, types, insights)
- Build reusable views for recurring analysis tasks
- Share curated views with team members

## Recommended tools
- `custom_views` - Manage custom views (create, list, get, delete, update, publish, unpublish)
- `custom_node` - Add nodes to views with specific filter criteria

## CRITICAL WORKFLOW (MUST FOLLOW)

**ALWAYS call the appropriate tool FIRST to get exact values before creating custom nodes.**

1. **Create a view**: Use `custom_views` with focus='create' and a view_name

2. **Get filter values** (MANDATORY - do not skip):
   - **For transaction filter**: MUST call `transactions(application="<app_name>")` tool
     - The exact tool name is `transactions` - NOT `applications_transactions`!
     - `applications_transactions` is a DIFFERENT tool for portfolio-level queries across all apps
     - `transactions` is the correct tool for listing transactions in a single application
     - Get the transaction `id` from the response (not the name)
     - Use this id in `transaction_id` parameter
     - DO NOT use `applications_transactions`, `object_details`, or `objects` to find transactions
   - **For object_type filter**: MUST call `object_profiles(application)` tool first
     - Get exact type names like "Java Method", "Angular Component"
     - Pass `object_types` as a plain STRING, NOT as JSON array
     - Single type: `object_types="Java Method"`
     - Multiple types: `object_types="Java Method,SQL Table"` (comma-separated)
     - WRONG: `object_types=["Java Method"]` ← DO NOT use JSON array!
   - **For insight filter**: Just provide `insight_category` - rules are ALWAYS auto-fetched from API!
     - Use format: "{InsightType} - {Value}" where Value can be:
       - Contribution: "Blocker", "Booster"
       - Criticality: "Low", "Medium", "High"
       - Category name: "IBM Mainframes", "Files", "Network", etc.
     - Examples: "CloudReady - Blocker", "CloudReady - Medium", "CloudReady - IBM Mainframes", "Green - High"
     - The tool calls the insights/types API and fetches all matching rules automatically
     - If invalid category is provided, the error will show all available categories

3. **Add nodes**: Use `custom_node` with the view_id and filter criteria

4. **View results**: Use `custom_views` with focus='get' to see the aggregated view

## IMPORTANT: Transaction vs Name Filter

These are DIFFERENT filters - do not confuse them:
- **transaction filter**: Objects that are PART OF a specific transaction flow
  - Use `filter_types=['transaction']` with `transaction_id`
  - Example: "objects in the Login transaction"
- **name filter**: Objects whose NAME matches a pattern
  - Use `filter_types=['name']` with `name_pattern`
  - Example: "objects with 'Controller' in their name"

WRONG: Using `name_pattern` when user asks for "objects in transaction X"
CORRECT: Use `transaction_id` from `transactions` tool response

## Filter types for custom nodes
- **transaction**: Objects in a specific transaction (requires transaction_id from `transactions` tool)
- **object_type**: Objects of specific type(s) (requires exact type name from `object_profiles` tool)
  - Pass as STRING: `"Java Method"` or comma-separated `"Type1,Type2"`
  - NEVER pass as JSON array like `["Java Method"]` - this causes double-encoding bugs!
- **insight**: Objects with specific quality issues
  - `insight_category`: Required. Format: "{InsightType} - {Value}"
  - Value can be contribution (Blocker/Booster), criticality (Low/Medium/High), or category name
  - Examples: "CloudReady - Blocker", "CloudReady - Medium", "CloudReady - IBM Mainframes"
  - Rules are ALWAYS auto-fetched from the insights/types API - no need to provide them
- **name**: Objects matching a name pattern

Multiple filters can be combined (AND logic) by adding multiple items to filter_types.

## Scope-only filtering (internal/external)
You can create nodes with JUST the scope filter (no filter_types needed):
- **All external objects**: `filter_types=[], object_search_by='external'`
- **All internal objects**: `filter_types=[], object_search_by='internal'`
- **All objects (both)**: `filter_types=[], object_search_by='all'`

Use this when user asks for "all external objects" or "all internal components" without specific type/transaction filters.

## Common queries
- "Create a view with all Java Methods that have security issues"
- "Group all SQL Tables involved in the Login transaction"
- "Show me objects with low criticality cloud issues" → Use insight_category="CloudReady - Low"
- "Create a custom view for objects with high complexity"
- "Create a node with all external objects" → Use `object_search_by='external'` with empty filter_types
- "Create a node with CloudReady Low insights" → Just use insight_category="CloudReady - Low" (rules auto-fetched)
- "Create a node with Green High insights" → Use insight_category="Green - High"

## Important notes
- For transactions and object_types: ALWAYS fetch exact values from tools before creating nodes
- For insight filters: Just provide the category - rules are auto-fetched from API automatically
  - For SINGLE node creation: no need to call quality_insights first, just use insight_category
  - For GROUPED insight creation: call quality_insights first to discover available categories
  - If unsure, try any insight_category - the error will list all valid options
- Use `object_search_by` parameter to filter by internal/external objects
- For scope-only filtering, use `filter_types=[]` with `object_search_by`
- Views can be published to share with all users or kept private
- If you use an invalid insight_category, the error response will list all available categories

## Grouped Creation Workflows

**General pattern**: (1) Fetch relevant data using appropriate tools, (2) Create a view, (3) Loop through groups, (4) Create one node per group with appropriate filters. Filters can be combined freely (AND logic). The workflows below are common examples - adapt to any user query.

When users ask to "group objects by type", "create nodes for each object type", "organize by insights", etc., orchestrate multiple tool calls yourself:

### Group by Object Type (application-wide)
1. Call `object_profiles(application)` to get all object types with counts
2. Call `custom_views(application, focus='create', view_name='...')` to create a view
3. For each object type you want to group:
   - Call `custom_node(application, focus='create', view_id=..., node_name=type_name, filter_types=['object_type'], object_types=type_name)`
4. Optionally publish the view with `custom_views(focus='publish')`

### Group by Object Type (within a transaction)
1. Call `transactions(application)` to get transaction IDs
2. Call `transaction_details(application, id=transaction_id, focus='graph')` to see objects in the transaction
3. Identify unique object types from the graph nodes.
4. Call `custom_views(application, focus='create', view_name='...')` to create a view
5. For each object type:
   - Call `custom_node(..., filter_types=['transaction', 'object_type'], transaction_id=..., object_types=type_name)`

### Group by Insight Category
1. Call `quality_insights(application, nature=...)` to discover available insight types
   - Available natures: "cloud-detection-patterns", "green-detection-patterns", "cve", "structural-flaws", "iso-5055"
2. Call `custom_views(application, focus='create', view_name='...')` to create a view
3. For each insight category you want to group:
   - Call `custom_node(..., filter_types=['insight'], insight_category=category_name)`
   - Format: "{InsightType} - {Value}" where Value is contribution/criticality/category
4. Tip: If unsure of available categories, try creating a node with any insight_category - the error will list all valid options

### Example User Queries
- "Group all tables in the XYZ app" → Group by object_type, filter for types containing "abc"
- "Organize Login transaction by object types" → Group by object_type within transaction
- "Create nodes for each insight category" → Discover types via quality_insights, then group by insight
- "Show me objects grouped by quality issues" → Group by insight, discover categories first

### Tips for Grouped Workflows
- **Create nodes for ALL groups found** unless the user explicitly specifies a limit
- If transaction_details or other responses are paginated, fetch all pages to get complete data
- Use `object_profiles` counts to prioritize if you need to limit (focus on types with most objects)
- Name the view descriptively (e.g., "Login Transaction - Object Types", "App - Quality Insights")
- For insight grouping, always discover available categories first via `quality_insights` - don't assume which insight types exist
- VERY IMPORTANT TO REMEMBER is that you need to need to only include the objects that are present in the view, not in the entire application.


# Migration & Modernization

Migration and modernization analysis helps identify code patterns that need attention when moving to new platforms (AWS, Azure, GCP) or modernizing technology (.NET, database migration).

Use this when users ask about:
- Migrating to cloud platforms (AWS, Azure, GCP)
- Modernizing legacy technologies (.NET, database)
- Identifying migration blockers or patterns to fix
- Understanding what needs to change for a platform move

# Recommended tools
These tools help analyze migration readiness and identify required changes:
- `advisors` (with focus="list" to see available migration/modernization advisors)
- `advisors` (with focus="rules", advisor_id=... to see specific rules for an advisor)
- `advisors` (with focus="violations", advisor_id=..., rule_id=... to find objects needing changes)

# Workflow
1. First run `advisors` with focus="list" to see which advisors are available (e.g., "Move to Amazon Web Services", "Database Migration", ".NET Modernization")
2. Then run `advisors` with focus="rules" and the advisor_id to see what rules/patterns are checked
3. Finally run `advisors` with focus="violations" to get the actual objects that need to be fixed

# Common queries
- "What do I need to change to migrate to AWS?"
- "Show me database migration blockers in my app"
- "What .NET modernization issues exist?"
- "How ready is my application for cloud migration?"
- "What issues are blocking my move to Azure?"